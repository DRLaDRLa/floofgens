# frozen_string_literal: true

class UserDataImport
  # Plans and performs a user data import.
  #
  # #preflight only reads. It runs at upload (for the preview), at confirm, and at the start
  # of every job run, so the preview and the actual import use the same rules.
  #
  # #run! writes in short transactions, each starting with UserDataImport#fence!. Phases run in
  # the order profile, sets, favorites; each is idempotent, so a resumed run continues where
  # the last one stopped without duplicating anything.
  #
  # Lock order matches the normal favorite path (FavoriteManager locks the post, then the
  # favorite counter callback updates user_statuses): import row -> posts (ascending id) ->
  # user_statuses.
  class Runner
    class CapacityExceeded < StandardError; end
    class Conflict < StandardError; end

    FAVORITE_BATCH_SIZE = 1_000
    LOOKUP_SLICE = 10_000
    REINDEX_SLICE = 5_000
    DEADLOCK_RETRIES = 3
    PREVIEW_ID_LIMIT = 1_000
    NAME_SUFFIX_LIMIT = 1_000
    NAME_RETRIES = 3
    PUBLIC_SET_MIN_AGE = 3.days

    attr_reader :import, :document

    def initialize(import, document: nil, token: nil)
      @import = import
      @user = import.user
      @document = document || Document.from_storage(import.document)
      @token = token
    end

    # The stored preview: the plan without the internal work lists and with long ID lists shortened.
    def self.preview_from(plan)
      plan.deep_dup.tap do |preview|
        preview["favorites"].delete("entries")
        %w[missing busy].each { |key| preview["favorites"][key] = preview["favorites"][key].first(PREVIEW_ID_LIMIT) }
        preview["sets"]["items"].each do |item|
          item.except!("post_ids", "recover_ids")
          item["missing_ids"] = item["missing_ids"].first(PREVIEW_ID_LIMIT)
        end
      end
    end

    # Conflicts that block the given categories, keyed by category.
    def self.conflicts_for(plan, categories)
      categories.index_with { |category| plan.dig(category, "conflict") }.compact
    end

    # Enqueues a reindex of every post this import touched, derived from the database, then
    # clears needs_reindex unless another write happened meanwhile (see
    # UserDataImport#acknowledge_reindex!). Without a token (DailyPruneJob) it only acts on
    # imports that no live worker owns.
    def self.reconcile_index!(import, token: nil)
      generation =
        if token
          UserDataImport.transaction do
            import.fence!(token)
            UserDataImport.where(id: import.id).pick(:reindex_generation)
          end
        else
          UserDataImport.where(id: import.id, needs_reindex: true)
                        .where("status = 'failed' OR (status = 'running' AND lease_expires_at < now())")
                        .pick(:reindex_generation)
        end
      return 0 if generation.nil?

      affected_post_ids(import.reload).each_slice(REINDEX_SLICE) do |slice|
        BulkIndexUpdateJob.set(queue: "low_prio").perform_async("Post", slice)
      end
      import.acknowledge_reindex!(generation, token: token)
    end

    def self.affected_post_ids(import)
      ids = []
      favorites = import.document.is_a?(Hash) ? import.document["favorites"] : nil
      if favorites.is_a?(Hash)
        favorites.keys.map(&:to_i).each_slice(LOOKUP_SLICE) do |slice|
          ids.concat(::Favorite.for_user(import.user_id).where(post_id: slice).pluck(:post_id))
        end
      end
      PostSet.where(id: import.set_map.values.map { |entry| entry["post_set_id"] }).pluck(:post_ids).each { |post_ids| ids.concat(post_ids) }
      ids.uniq
    end

    # What has been committed so far, for status pages and failure messages.
    def self.progress_summary(import)
      results = import.results
      parts = []
      favorites_total = results.dig("baseline", "favorites_new").to_i
      if import.import_favorites && favorites_total > 0
        parts << "#{results.dig('favorites', 'imported').to_i} of #{favorites_total} favorites"
      end
      sets_total = results.dig("baseline", "sets_total").to_i
      if import.import_sets && sets_total > 0
        done = results.dig("sets", "created").to_h.size + results.dig("sets", "merged").to_h.size
        parts << "#{done} of #{sets_total} sets"
      end
      parts << "profile #{import.phase_done?('profile') ? 'done' : 'not done'}" if import.import_profile
      parts.join(", ")
    end

    # Inserts each recovered post right after its nearest earlier neighbour (in source order)
    # that is already in the set, leaving the user's own additions and order alone. Recovered
    # posts with no earlier neighbour go first.
    def self.merge_in_source_order(source, current, recover)
      current_set = current.to_set
      recover_set = recover.to_set
      after = {}
      last = nil
      source.each do |id|
        if recover_set.include?(id)
          (after[last] ||= []) << id
          last = id
        elsif current_set.include?(id)
          last = id
        end
      end

      expand = ->(key) do
        out = []
        stack = after.fetch(key, []).reverse
        while (id = stack.pop)
          out << id
          stack.concat(after.fetch(id, []).reverse)
        end
        out
      end
      expand.call(nil) + current.flat_map { |id| [id, *expand.call(id)] }
    end

    # ========== Preflight ========== #

    def preflight
      load_state
      { "favorites" => plan_favorites, "sets" => plan_sets, "profile" => plan_profile }
    end

    # ========== Run ========== #

    def run!
      raise ArgumentError, "run! needs a run token" if @token.blank?

      self.class.reconcile_index!(import, token: @token) if import.reload.needs_reindex
      plan = preflight
      conflicts = self.class.conflicts_for(plan, import.selected_categories)
      raise Conflict, conflicts.values.join(" ") if conflicts.any?

      record_baseline(plan)
      run_profile(plan["profile"]) if import.import_profile && !import.reload.phase_done?("profile")
      run_sets(plan["sets"]) if import.import_sets && !import.reload.phase_done?("sets")
      run_favorites(plan["favorites"]) if import.import_favorites && !import.reload.phase_done?("favorites")

      self.class.reconcile_index!(import, token: @token) if import.reload.needs_reindex
      import.complete!(@token)
    end

    private

    # ---------- state ---------- #

    def load_state
      @user.reload
      @posts = {}
      document.referenced_post_ids.each_slice(LOOKUP_SLICE) do |slice|
        Post.where(id: slice).pluck(:id, :bit_flags, :is_deleted).each { |id, flags, deleted| @posts[id] = [flags, deleted] }
      end
      @existing_favorites = ::Favorite.for_user(@user.id).pluck(:post_id).to_set
      @set_map = UserDataImport.restored_sets_for(@user)
    end

    def transfer_flag
      @transfer_flag ||= Post.flag_value_for("favorites_transfer_in_progress")
    end

    def busy?(post_id)
      @posts[post_id][0].anybits?(transfer_flag)
    end

    def may_publish_sets?
      @user.is_staff? || !@user.younger_than(PUBLIC_SET_MIN_AGE)
    end

    def scoped_as_user(&)
      # The import doesn't keep the uploader's IP; 127.0.0.1 is what background jobs use.
      CurrentUser.scoped(@user, &)
    end

    def fenced(&)
      ActiveRecord::Base.transaction do
        import.fence!(@token)
        yield
      end
    end

    # A batch is one transaction and fully idempotent, so a deadlock (possible against
    # existing bulk jobs that update posts in arbitrary order) just retries it.
    def with_deadlock_retry
      attempts = 0
      begin
        yield
      rescue ActiveRecord::Deadlocked
        attempts += 1
        raise if attempts > DEADLOCK_RETRIES

        sleep(0.2 * attempts)
        retry
      end
    end

    # First run only: what the import set out to do, and empty result sections to fill in.
    def record_baseline(plan)
      baseline = {
        "favorites_new" => plan.dig("favorites", "new"), "favorites_already" => plan.dig("favorites", "already"),
        "sets_total" => plan.dig("sets", "total"),
      }
      fenced do
        UserDataImport.where(id: import.id).where("NOT (results ? 'baseline')").update_all([
          "results = results || ?::jsonb",
          { "baseline" => baseline, "sets" => { "created" => {}, "merged" => {}, "failed" => {} } }.to_json,
        ])
      end
    end

    # ---------- favorites ---------- #

    def plan_favorites
      new_entries = []
      already = []
      missing = []
      busy = []
      document.favorites.each do |favorite|
        id = favorite.post_id
        if @existing_favorites.include?(id) then already << id
        elsif !@posts.key?(id) then missing << id
        elsif busy?(id) then busy << id
        else new_entries << favorite
        end
      end

      capacity = [@user.favorite_limit - @user.favorite_count, 0].max
      conflict =
        if new_entries.any? && Security::Lockdown.favorites_disabled? && !@user.is_staff?
          "Favorites are currently disabled on this site."
        elsif new_entries.size > capacity
          "Restoring your favorites needs room for #{new_entries.size} more, but your account can only add #{capacity} " \
            "(limit #{@user.favorite_limit}). Remove some favorites and try again, or leave favorites out."
        end

      {
        "total" => document.favorites.size, "new" => new_entries.size, "already" => already.size,
        "missing_count" => missing.size, "missing" => missing, "busy_count" => busy.size, "busy" => busy,
        "capacity" => capacity, "conflict" => conflict,
        "entries" => new_entries.map { |fav| [fav.post_id, fav.favorited_at.iso8601(6)] },
      }
    end

    def run_favorites(plan)
      unavailable = []
      plan["entries"].each_slice(FAVORITE_BATCH_SIZE) do |batch|
        inserted, skipped, generation = favorites_batch(batch)
        unavailable.concat(skipped)
        next unless generation

        BulkIndexUpdateJob.set(queue: "low_prio").perform_async("Post", inserted)
        import.acknowledge_reindex!(generation, token: @token)
      end

      fenced do
        import.merge_results!(
          "favorites" => { "missing" => plan["missing"], "busy" => plan["busy"], "unavailable" => unavailable },
          "phases" => { "favorites" => "done" },
        )
      end
    end

    # One batch: lock the posts in ascending id order, insert what isn't there yet, adjust the
    # counters by exactly the inserted rows, and refuse to go past the favorite limit.
    def favorites_batch(batch)
      with_deadlock_retry do
        inserted = []
        skipped = []
        generation = nil
        fenced do
          ids = batch.map(&:first)
          locked = Post.where(id: ids).order(:id).lock("FOR UPDATE").pluck(:id, :bit_flags).to_h
          usable = batch.select { |id, _| locked.key?(id) && !locked[id].anybits?(transfer_flag) }
          skipped = ids - usable.map(&:first)

          if usable.any?
            rows = usable.map { |id, time| { user_id: @user.id, post_id: id, created_at: Time.iso8601(time) } }
            inserted = ::Favorite.insert_all(rows, unique_by: :index_favorites_on_user_id_and_post_id, returning: :post_id).rows.flatten
          end

          if inserted.any?
            Post.where(id: inserted).update_all("fav_count = fav_count + 1")
            if adjust_favorite_count(inserted.size) > @user.favorite_limit
              raise CapacityExceeded, "Your favorite limit (#{@user.favorite_limit}) was reached while restoring. " \
                                      "Remove some favorites, then resume the import."
            end
            import.increment_result!("favorites", "imported", inserted.size)
            generation = import.record_write!
          end
        end
        [inserted, skipped, generation]
      end
    end

    def adjust_favorite_count(amount)
      UserStatus.connection.select_value(UserStatus.sanitize_sql([
        "UPDATE user_statuses SET favorite_count = favorite_count + ? WHERE user_id = ? RETURNING favorite_count", amount, @user.id,
      ])).to_i
    end

    # ---------- sets ---------- #

    def plan_sets
      owned = PostSet.where(creator_id: @user.id).count
      reserved = { "name" => Set.new, "shortname" => Set.new }
      items = document.sets.map do |set|
        present = set.post_ids.select { |id| @posts.key?(id) }
        item = {
          "source_id" => set.source_id, "key" => set.map_key, "name" => set.name, "short_name" => set.short_name,
          "total" => set.post_ids.size, "present" => present.size, "missing_ids" => set.post_ids - present, "post_ids" => present,
        }
        mapping = @set_map[set.map_key]
        mapping ? plan_merge(item, mapping) : plan_create(item, set, reserved)
      end

      new_count = items.count { |item| item["action"] == "create" }
      too_big = items.find { |item| item["action"] == "merge" && item["size_after"] > Document.max_posts_per_set }
      conflict =
        if items.any? && Security::Lockdown.post_sets_disabled? && !@user.is_staff?
          "Sets are currently disabled on this site."
        elsif owned + new_count > PostSet::MAX_SETS_PER_USER
          "Restoring #{new_count} new #{'set'.pluralize(new_count)} would exceed the limit of #{PostSet::MAX_SETS_PER_USER} sets " \
            "(you have #{owned}). Delete some sets and try again, or leave sets out."
        elsif too_big
          "Restoring the missing posts of \"#{too_big['name']}\" would exceed #{Document.max_posts_per_set} posts. " \
            "Remove some posts from that set and try again, or leave sets out."
        elsif items.any? { |item| item["action"] == "create" && item["resolved_name"].nil? }
          "A set name couldn't be made unique."
        end

      { "total" => items.size, "owned" => owned, "new" => new_count, "items" => items, "conflict" => conflict }
    end

    def plan_merge(item, mapping)
      current = PostSet.where(id: mapping["post_set_id"]).pick(:post_ids) || []
      current_set = current.to_set
      recover = mapping["missing"].select { |id| @posts.key?(id) && current_set.exclude?(id) }
      item.merge(
        "action" => "merge", "post_set_id" => mapping["post_set_id"], "recover_ids" => recover,
        "recoverable" => recover.size, "size_after" => current.size + recover.size,
        "missing_ids" => mapping["missing"].reject { |id| @posts.key?(id) }
      )
    end

    def plan_create(item, set, reserved)
      name = unique_candidate(set.name, "name", 100, reserved["name"]) { |base, n, max| "#{base[0, max - " (#{n})".length]} (#{n})" }
      short_name = unique_candidate(set.short_name, "shortname", 50, reserved["shortname"]) { |base, n, max| "#{base[0, max - "_#{n}".length]}_#{n}" }
      item.merge(
        "action" => "create", "resolved_name" => name, "resolved_short_name" => short_name,
        "renamed" => name != set.name || short_name != set.short_name,
        "is_public" => set.is_public && may_publish_sets?, "made_private" => set.is_public && !may_publish_sets?
      )
    end

    # The base value, or the first suffixed variant (" (2)", "_2", ...) that no set uses yet,
    # case-insensitively, trimmed to fit `max` characters.
    def unique_candidate(base, column, max, reserved)
      [base].chain((2..NAME_SUFFIX_LIMIT).lazy.map { |n| yield(base, n, max) }).find do |candidate|
        next false if reserved.include?(candidate.downcase)
        next false if PostSet.where("lower(#{column}) = ?", candidate.downcase).exists?

        reserved << candidate.downcase
      end
    end

    def run_sets(plan)
      by_key = document.sets.index_by(&:map_key)
      plan["items"].each do |item|
        set = by_key.fetch(item["key"])
        item["action"] == "merge" ? merge_set(set, item) : create_set(set, item)
      end
      fenced { import.merge_results!("phases" => { "sets" => "done" }) }
    end

    def create_set(set, item)
      names = [item["resolved_name"], item["resolved_short_name"]]
      attempts = 0
      begin
        generation = with_deadlock_retry do
          fenced do
            UserStatus.for_user(@user.id).lock("FOR UPDATE").pick(:user_id)
            if PostSet.where(creator_id: @user.id).count >= PostSet::MAX_SETS_PER_USER
              raise CapacityExceeded, "The set limit (#{PostSet::MAX_SETS_PER_USER}) was reached while restoring. " \
                                      "Delete some sets, then resume the import."
            end

            post_set = scoped_as_user do
              PostSet.create!(
                name: names[0], shortname: names[1], description: set.description,
                is_public: item["is_public"], transfer_on_delete: set.transfer_on_delete, post_ids: item["post_ids"],
                created_at: set.created_at, updated_at: set.updated_at,
                creator: @user, restoring: true
              )
            end
            import.record_set_mapping!(set.map_key, post_set.id, item["missing_ids"])
            import.put_result!(["sets", "created", set.source_id], {
              "post_set_id" => post_set.id, "name" => post_set.name, "short_name" => post_set.shortname,
              "renamed" => post_set.name != set.name || post_set.shortname != set.short_name,
              "made_private" => item["made_private"], "posts" => item["post_ids"].size, "missing" => item["missing_ids"].size,
            })
            import.record_write!
          end
        end
        import.acknowledge_reindex!(generation, token: @token)
      rescue ActiveRecord::RecordInvalid => e
        attempts += 1
        if attempts <= NAME_RETRIES && name_taken?(e.record)
          # Someone took the name after preflight. Resolve again against the current sets.
          names = [
            unique_candidate(set.name, "name", 100, Set.new) { |base, n, max| "#{base[0, max - " (#{n})".length]} (#{n})" },
            unique_candidate(set.short_name, "shortname", 50, Set.new) { |base, n, max| "#{base[0, max - "_#{n}".length]}_#{n}" },
          ]
          retry
        end
        fenced { import.put_result!(["sets", "failed", set.source_id], { "name" => set.name, "errors" => e.record.errors.full_messages }) }
      end
    end

    def name_taken?(record)
      record.errors.details.values_at(:name, :shortname).flatten.compact.any? { |detail| detail[:error] == :taken }
    end

    def merge_set(set, item)
      # Created earlier in this same import: nothing to merge, it's already reported.
      return if import.reload.results.dig("sets", "created", set.source_id.to_s) && item["recoverable"] == 0

      generation = with_deadlock_retry do
        fenced do
          post_set = PostSet.where(id: item["post_set_id"], creator_id: @user.id).lock("FOR UPDATE").first
          raise Conflict, "The set \"#{set.name}\" was deleted during the import. Resume to recreate it." unless post_set

          current = post_set.post_ids
          current_set = current.to_set
          recover = item["recover_ids"].reject { |id| current_set.include?(id) }
          if recover.any?
            merged = self.class.merge_in_source_order(set.post_ids, current, recover)
            if merged.size > Document.max_posts_per_set
              raise CapacityExceeded, "Restoring the missing posts of \"#{post_set.name}\" would exceed #{Document.max_posts_per_set} posts."
            end

            scoped_as_user do
              post_set.post_ids = merged
              post_set.save!
            end
          end
          # Recorded on this import too, so it outlives older imports and is reconciled with it.
          import.record_set_mapping!(set.map_key, post_set.id, item["missing_ids"])
          import.put_result!(["sets", "merged", set.source_id], {
            "post_set_id" => post_set.id, "name" => post_set.name, "recovered" => recover.size, "still_missing" => item["missing_ids"].size,
          })
          recover.any? ? import.record_write! : nil
        end
      end
      import.acknowledge_reindex!(generation, token: @token) if generation
    end

    # ---------- profile ---------- #

    def plan_profile
      backup = document.profile
      fields = %w[about artinfo].index_with do |field|
        current = @user.public_send(:"profile_#{field}").to_s
        value = backup[field.to_sym]
        { "backup_empty" => value.empty?, "current_empty" => current.blank?, "differs" => !value.empty? && value != current }
      end

      avatar = backup[:avatar] && begin
        info = @posts[backup[:avatar][:post_id]]
        reason = if info.nil?
                   "missing"
                 elsif info[1]
                   "deleted"
                 end
        {
          "post_id" => backup[:avatar][:post_id], "cropped" => backup[:avatar][:cropped], "usable" => reason.nil?,
          "reason" => reason, "current_empty" => @user.avatar_id.nil?, "differs" => @user.avatar_id != backup[:avatar][:post_id],
        }
      end

      replace_relevant = fields.values.any? { |f| f["differs"] && !f["current_empty"] } ||
                         (avatar.present? && avatar["usable"] && avatar["differs"] && !avatar["current_empty"])
      { "fields" => fields, "avatar" => avatar, "replace_relevant" => replace_relevant, "conflict" => nil }
    end

    def run_profile(plan)
      fenced do
        user = User.find(@user.id)
        changes = {}
        report = {}

        plan["fields"].each do |field, info|
          column = :"profile_#{field}"
          report[field] = profile_action(info["backup_empty"], info["differs"], user[column].blank?)
          changes[column] = document.profile[field.to_sym] if %w[restored replaced].include?(report[field])
        end

        avatar = plan["avatar"]
        report["avatar"] =
          if avatar.nil? then "none_in_backup"
          elsif !avatar["usable"] then "post_#{avatar['reason']}"
          else profile_action(false, avatar["differs"], user.avatar_id.nil?)
          end
        changes[:avatar_id] = avatar["post_id"] if %w[restored replaced].include?(report["avatar"])
        # The crop itself isn't in the backup, so the avatar is restored uncropped.
        report["avatar_was_cropped"] = changes.key?(:avatar_id) && avatar["cropped"]

        if changes.any?
          if scoped_as_user { user.update(changes) }
            report["changed"] = changes.keys.map(&:to_s)
          else
            report = { "error" => user.errors.full_messages }
          end
        end
        import.merge_results!("profile" => report, "phases" => { "profile" => "done" })
      end
    end

    def profile_action(backup_empty, differs, current_empty)
      if backup_empty then "empty_in_backup"
      elsif !differs then "unchanged"
      elsif current_empty then "restored"
      elsif import.replace_profile then "replaced"
      else "kept_existing"
      end
    end
  end
end
