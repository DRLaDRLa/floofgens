# frozen_string_literal: true

require "rails_helper"

RSpec.describe UserDataImport::Runner do
  include_context "as admin"
  include_context "without e6ai post ID limits"

  let(:user) { create(:user, created_at: 2.weeks.ago) }
  let(:same_second) { "2026-03-01T10:00:00Z" }

  def bulk_index_jobs
    BulkIndexUpdateJob.jobs.map { |job| job["args"].last }
  end

  describe "favorites" do
    it "keeps the file order for same-second favorites through storage, and lists them newest first" do
      [190_900, 190_012, 190_450].each { |id| insert_post(id) }
      import = create_import(user, parse_backup(favorites: { "190900" => same_second, "190012" => same_second, "190450" => same_second }))
      expect(import.reload.document["favorites"].keys).to eq(%w[190012 190450 190900]) # jsonb sorted them

      expect(run_import(import)).to be_is_completed
      base = Time.utc(2026, 3, 1, 10)
      expect(Favorite.for_user(user.id).order(:created_at).pluck(:post_id, :created_at)).to eq([
        [190_900, base], [190_012, base + Rational(1, 1_000_000)], [190_450, base + Rational(2, 1_000_000)],
      ])
      expect(PostSets::Favorites.new(user, 1, limit: 10).posts.map(&:id)).to eq([190_450, 190_012, 190_900])
    end

    it "preserves timestamps, leaves existing favorites alone and keeps the counters consistent" do
      older = insert_post(190_101)
      existing = insert_post(190_102)
      missing_id = 190_199
      FavoriteManager.add!(user: user, post: existing)
      existing_time = Favorite.find_by(user_id: user.id, post_id: existing.id).created_at

      import = create_import(user, parse_backup(favorites: {
        older.id => "2022-11-05T05:05:05Z", # before the post was created: imported unchanged
        existing.id => "2023-01-01T00:00:00Z",
        missing_id => same_second,
      }))
      run_import(import)

      expect(Favorite.find_by(user_id: user.id, post_id: older.id).created_at).to eq(Time.utc(2022, 11, 5, 5, 5, 5))
      expect(Favorite.find_by(user_id: user.id, post_id: existing.id).created_at).to eq(existing_time)
      expect(import.results["favorites"]).to include("imported" => 1, "missing" => [missing_id])
      expect(import.results.dig("baseline", "favorites_already")).to eq(1)
      expect(favorite_counts_consistent?(user, [older.id, existing.id])).to be(true)
      expect(bulk_index_jobs).to include([older.id])
    end

    it "skips a post that became busy after preflight, under the post lock" do
      post = insert_post(190_201)
      import = create_import(user, parse_backup(favorites: { post.id => same_second }))
      token = UserDataImport.claim!(import.id)
      runner = described_class.new(import.reload, token: token)
      stale_plan = runner.preflight
      Post.where(id: post.id).update_all(bit_flags: Post.flag_value_for("favorites_transfer_in_progress"))
      allow(runner).to receive(:preflight).and_return(stale_plan)

      runner.run!
      expect(Favorite.where(post_id: post.id)).to be_empty
      expect(import.reload.results.dig("favorites", "unavailable")).to eq([post.id])
    end

    it "refuses favorites while they're locked down" do
      allow(Security::Lockdown).to receive(:favorites_disabled?).and_return(true)
      post = insert_post(190_301)
      import = run_import(create_import(user, parse_backup(favorites: { post.id => same_second })))

      expect(import).to be_is_failed
      expect(import.error_message).to eq("Nothing was imported. Favorites are currently disabled on this site.")
      expect(Favorite.where(post_id: post.id)).to be_empty
    end

    it "retries a batch that hits a deadlock" do
      post = insert_post(190_401)
      calls = 0
      allow(Favorite).to receive(:insert_all).and_wrap_original do |original, *args, **kwargs|
        calls += 1
        raise ActiveRecord::Deadlocked, "deadlock detected" if calls == 1

        original.call(*args, **kwargs)
      end
      allow_any_instance_of(described_class).to receive(:sleep) # rubocop:disable RSpec/AnyInstance

      expect(run_import(create_import(user, parse_backup(favorites: { post.id => same_second })))).to be_is_completed
      expect(calls).to eq(2)
      expect(favorite_counts_consistent?(user, [post.id])).to be(true)
    end
  end

  describe "capacity" do
    let(:posts) { [190_501, 190_502, 190_503].map { |id| insert_post(id) } }
    let(:backup) { parse_backup(favorites: posts.to_h { |post| [post.id, same_second] }) }

    it "blocks favorites before any write when they don't fit" do
      allow_any_instance_of(User).to receive(:favorite_limit).and_return(2) # rubocop:disable RSpec/AnyInstance
      import = run_import(create_import(user, backup, sets: false))

      expect(import).to be_is_failed
      expect(import.error_message).to start_with("Nothing was imported. Restoring your favorites needs room for 3 more")
      expect(Favorite.for_user(user.id)).to be_empty
      expect(user.reload.user_status.favorite_count).to eq(0)
    end

    it "accepts favorites that fit exactly" do
      allow_any_instance_of(User).to receive(:favorite_limit).and_return(3) # rubocop:disable RSpec/AnyInstance
      expect(run_import(create_import(user, backup))).to be_is_completed
      expect(Favorite.for_user(user.id).count).to eq(3)
    end

    it "keeps committed batches when capacity runs out mid-run, then resumes after room is freed" do
      stub_const("#{described_class}::FAVORITE_BATCH_SIZE", 1)
      allow_any_instance_of(User).to receive(:favorite_limit).and_return(3) # rubocop:disable RSpec/AnyInstance
      extra = insert_post(190_599)
      import = create_import(user, backup)
      batches = 0
      allow(described_class).to receive(:new).and_wrap_original do |original, *args, **kwargs|
        original.call(*args, **kwargs).tap do |runner|
          allow(runner).to receive(:favorites_batch).and_wrap_original do |batch_method, batch|
            batches += 1
            # The user favorites something by hand while the import runs.
            FavoriteManager.add!(user: user, post: extra, force: true) if batches == 2
            batch_method.call(batch)
          end
        end
      end

      run_import(import)
      expect(import).to be_is_failed
      expect(import.error_message).to start_with("Partially restored: 2 of 3 favorites.")
      expect(import.error_message).to include("favorite limit (3) was reached")
      expect(import).not_to be_phase_done("favorites")
      expect(favorite_counts_consistent?(user, posts.map(&:id) + [extra.id])).to be(true)

      FavoriteManager.remove!(user: user, post: extra)
      expect(import.requeue!).to eq(1)
      expect(run_import(import)).to be_is_completed
      expect(import.results.dig("favorites", "imported")).to eq(3)
      expect(Favorite.for_user(user.id).pluck(:post_id)).to match_array(posts.map(&:id))
      expect(favorite_counts_consistent?(user, posts.map(&:id) + [extra.id])).to be(true)
    end

    it "blocks sets before any write when they'd exceed the set limit" do
      stub_const("PostSet::MAX_SETS_PER_USER", 2)
      create(:post_set, creator: user)
      sets = { 1 => backup_set(name: "One", short_name: "one"), 2 => backup_set(name: "Two", short_name: "two") }
      import = run_import(create_import(user, parse_backup(sets: sets), favorites: false))

      expect(import).to be_is_failed
      expect(import.error_message).to start_with("Nothing was imported. Restoring 2 new sets would exceed the limit of 2 sets")
      expect(PostSet.where(creator_id: user.id).count).to eq(1)
    end
  end

  describe "sets" do
    it "creates new sets with the backup's metadata, order and timestamps, skipping missing posts" do
      a = insert_post(190_601)
      b = insert_post(190_602)
      backup = parse_backup(sets: { 42 => backup_set(
        name: "Example Set", short_name: "example", description: "Some [b]dtext[/b]", is_public: true,
        transfer_on_delete: true, post_ids: [b.id, 190_699, a.id]
      ) })
      import = run_import(create_import(user, backup))

      set = PostSet.find_by!(creator_id: user.id)
      expect(set.id).not_to eq(42)
      expect(set).to have_attributes(name: "Example Set", shortname: "example", description: "Some [b]dtext[/b]",
                                     is_public: true, transfer_on_delete: true, post_ids: [b.id, a.id])
      expect(set.created_at).to eq(Time.utc(2026, 1, 1, 12))
      expect(set.updated_at).to eq(Time.utc(2026, 2, 1, 12))
      expect(user.reload.user_status.set_count).to eq(1)
      expect(import.results.dig("sets", "created", "42")).to include("post_set_id" => set.id, "missing" => 1, "renamed" => false)
    end

    it "renames on name collisions, short name collisions and both" do
      other = create(:user)
      create(:post_set, creator: other, name: "Taken Name", shortname: "free_one")
      create(:post_set, creator: other, name: "Other Name", shortname: "taken_short")
      create(:post_set, creator: other, name: "Both Taken", shortname: "both_taken")
      backup = parse_backup(sets: {
        1 => backup_set(name: "taken name", short_name: "new_short"),
        2 => backup_set(name: "Unused Name", short_name: "taken_short"),
        3 => backup_set(name: "Both Taken", short_name: "both_taken"),
      })
      run_import(create_import(user, backup))

      expect(PostSet.where(creator_id: user.id).order(:id).pluck(:name, :shortname)).to eq([
        ["taken name (2)", "new_short"], ["Unused Name", "taken_short_2"], ["Both Taken (2)", "both_taken_2"],
      ])
    end

    it "makes public sets private for accounts younger than 3 days, but not for staff" do
      young = create(:user, created_at: 1.hour.ago)
      run_import(create_import(young, parse_backup(sets: { 1 => backup_set(name: "Young Set", short_name: "young_set", is_public: true) })))
      expect(PostSet.find_by!(creator_id: young.id).is_public).to be(false)

      staff = create(:janitor_user, created_at: 1.hour.ago)
      run_import(create_import(staff, parse_backup(sets: { 1 => backup_set(name: "Staff Set", short_name: "staff_set", is_public: true) })))
      expect(PostSet.find_by!(creator_id: staff.id).is_public).to be(true)
    end

    it "refuses sets while they're locked down" do
      allow(Security::Lockdown).to receive(:post_sets_disabled?).and_return(true)
      import = run_import(create_import(user, parse_backup(sets: { 1 => backup_set }), favorites: false))

      expect(import).to be_is_failed
      expect(import.error_message).to eq("Nothing was imported. Sets are currently disabled on this site.")
      expect(PostSet.where(creator_id: user.id)).to be_empty
    end

    it "is exempt from the hourly set limit, which still applies to normal sets" do
      create_list(:post_set, 7, creator: user)
      import = run_import(create_import(user, parse_backup(sets: { 1 => backup_set(name: "Restored", short_name: "restored") })))
      expect(import).to be_is_completed
      expect(PostSet.where(creator_id: user.id).count).to eq(8)

      expect(build(:post_set, creator: user)).not_to be_valid
    end

    describe "resuming after sets were restored" do
      let(:a) { insert_post(190_701) }
      let(:c) { insert_post(190_703) }
      let(:backup) { parse_backup(favorites: { 190_702 => same_second }, sets: { 5 => backup_set(post_ids: [a.id, 190_702, c.id]) }) }

      # As if the run had stopped after creating the set but before finishing the sets and
      # favorites phases, then gets resumed.
      def interrupt_and_resume(import)
        import.update_columns(status: "failed", document: backup.to_storage,
                              results: import.results.merge("phases" => import.results["phases"].except("sets", "favorites")))
        expect(import.requeue!).to eq(1)
        run_import(import)
      end

      it "recognizes the restored set and merges posts found since in place" do
        import = run_import(create_import(user, backup))
        set = PostSet.find_by!(creator_id: user.id)
        expect(set.post_ids).to eq([a.id, c.id])

        own = insert_post(190_799)
        set.update!(post_ids: [own.id, a.id, c.id]) # the user's own edit
        b = insert_post(190_702)

        import = interrupt_and_resume(import)
        expect(import).to be_is_completed
        expect(PostSet.where(creator_id: user.id).count).to eq(1)
        expect(set.reload.post_ids).to eq([own.id, a.id, b.id, c.id])
        expect(Favorite.find_by(user_id: user.id, post_id: b.id).created_at).to eq(Time.utc(2026, 3, 1, 10))
        expect(import.results.dig("sets", "merged", "5")).to include("recovered" => 1, "still_missing" => 0)
      end

      it "doesn't add back posts the user removed after restoring" do
        insert_post(190_702)
        import = run_import(create_import(user, backup))
        set = PostSet.find_by!(creator_id: user.id)
        set.update!(post_ids: [a.id])

        interrupt_and_resume(import)
        expect(set.reload.post_ids).to eq([a.id])
      end

      it "recreates a restored set that was deleted" do
        import = run_import(create_import(user, backup))
        PostSet.find_by!(creator_id: user.id).destroy!

        interrupt_and_resume(import)
        expect(PostSet.where(creator_id: user.id).count).to eq(1)
      end
    end

    it "merges recovered posts after their nearest earlier neighbour" do
      merge = described_class.method(:merge_in_source_order)
      expect(merge.call([1, 2, 3, 4], [1, 4], [2, 3])).to eq([1, 2, 3, 4])
      expect(merge.call([1, 2, 3], [9, 3], [1, 2])).to eq([1, 2, 9, 3])
      expect(merge.call([1, 2, 3], [3, 1], [2])).to eq([3, 1, 2])
    end
  end

  describe "profile" do
    let(:avatar_post) { insert_post(190_801) }
    let(:backup) { parse_backup(about: "Backup about", artinfo: "Backup art", avatar: { "post_id" => avatar_post.id, "cropped" => true }) }

    # The user factory fills in profile text; these examples start from an empty profile.
    before { user.update_columns(profile_about: "", profile_artinfo: "") }

    it "changes nothing unless the profile is selected" do
      run_import(create_import(user, backup))
      expect(user.reload).to have_attributes(profile_about: "", profile_artinfo: "", avatar_id: nil)
    end

    it "fills empty fields only, and never marks the avatar as cropped" do
      user.update_columns(profile_artinfo: "Mine")
      import = run_import(create_import(user, backup, profile: true))

      expect(user.reload).to have_attributes(profile_about: "Backup about", profile_artinfo: "Mine", avatar_id: avatar_post.id)
      expect(user.has_cropped_avatar?).to be(false)
      expect(import.results["profile"]).to include("about" => "restored", "artinfo" => "kept_existing", "avatar" => "restored", "avatar_was_cropped" => true)
    end

    it "replaces existing values when asked to" do
      user.update_columns(profile_about: "Mine", profile_artinfo: "Mine too")
      run_import(create_import(user, backup, profile: true, replace_profile: true))
      expect(user.reload).to have_attributes(profile_about: "Backup about", profile_artinfo: "Backup art")
    end

    it "skips avatars whose post is missing or deleted" do
      import = run_import(create_import(user, parse_backup(avatar: { "post_id" => 190_899, "cropped" => false }), profile: true))
      expect(import.results.dig("profile", "avatar")).to eq("post_missing")

      import.destroy! # one import per user
      deleted = insert_post(190_898, is_deleted: true)
      import = run_import(create_import(user, parse_backup(avatar: { "post_id" => deleted.id, "cropped" => false }), profile: true))
      expect(import.results.dig("profile", "avatar")).to eq("post_deleted")
      expect(user.reload.avatar_id).to be_nil
    end
  end

  describe "failure handling" do
    it "fails without any writes when the stored backup no longer validates" do
      post = insert_post(190_901)
      import = create_import(user, parse_backup(favorites: { post.id => same_second }))
      import.update_columns(document: import.document.merge("favorite_order" => []))

      expect(run_import(import)).to be_is_failed
      expect(import.error_message).to start_with("Nothing was imported. The favorites' order record")
      expect(Favorite.for_user(user.id)).to be_empty
    end
  end

  describe "reindex reconciliation" do
    let(:posts) { [190_951, 190_952].map { |id| insert_post(id) } }
    let(:backup) { parse_backup(favorites: posts.to_h { |post| [post.id, same_second] }) }

    # Makes BulkIndexUpdateJob enqueues fail for the post IDs `failing` currently returns.
    def fail_bulk_index_enqueues(failing)
      allow(BulkIndexUpdateJob).to receive(:set).and_wrap_original do |original, *args|
        original.call(*args).tap do |setter|
          allow(setter).to receive(:perform_async).and_wrap_original do |enqueue, klass, ids|
            raise "redis down" if failing.call == ids

            enqueue.call(klass, ids)
          end
        end
      end
    end

    it "keeps the flag across a resumed run that crashes again, and reconciles everything later" do
      stub_const("#{described_class}::FAVORITE_BATCH_SIZE", 1)
      first, second = posts.map(&:id)
      failing = [first]
      fail_bulk_index_enqueues(-> { failing })
      import = create_import(user, backup)

      run_import(import) # batch 1 commits, then its enqueue fails
      expect(import).to be_is_failed
      expect(import.error_message).to start_with("Partially restored: 1 of 2 favorites.")
      expect(import.needs_reindex).to be(true)
      generation = import.reindex_generation

      failing = [second]
      expect(import.requeue!).to eq(1)
      run_import(import) # reconciles batch 1, commits batch 2, then its enqueue fails
      expect(import).to be_is_failed
      expect(import.needs_reindex).to be(true)
      expect(import.reindex_generation).to be > generation
      expect(bulk_index_jobs).to include([first])

      failing = nil
      BulkIndexUpdateJob.jobs.clear
      UserDataImport.prune!
      expect(bulk_index_jobs.flatten).to contain_exactly(first, second)
      expect(import.reload.needs_reindex).to be(false)
    end

    it "doesn't clear the flag when a write happens during reconciliation" do
      import = create_import(user, backup)
      import.update_columns(status: "failed", needs_reindex: true, reindex_generation: 1)
      allow(described_class).to receive(:affected_post_ids).and_wrap_original do |original, *args|
        UserDataImport.where(id: import.id).update_all("reindex_generation = reindex_generation + 1")
        original.call(*args)
      end

      expect(described_class.reconcile_index!(import)).to eq(0)
      expect(import.reload.needs_reindex).to be(true)
    end

    it "leaves imports with a live lease to their worker" do
      import = create_import(user, backup)
      import.update_columns(status: "running", needs_reindex: true, lease_expires_at: 5.minutes.from_now)

      UserDataImport.prune!
      expect(BulkIndexUpdateJob.jobs).to be_empty
      expect(import.reload.needs_reindex).to be(true)
    end
  end

  it "restores a large backup without truncating it" do
    template = create(:post).attributes.except("id", "md5", "change_seq")
    ids = Post.insert_all!(Array.new(20_000) { |i| template.merge("md5" => Digest::MD5.hexdigest("import-#{i}")) }, returning: :id).rows.flatten
    favorites = ids.each_with_index.to_h { |id, i| [id, Time.utc(2025, 1, 1).advance(seconds: i).iso8601] }
    set_ids = ids.first(10_000).reverse

    import = run_import(create_import(user, parse_backup(favorites: favorites, sets: { 1 => backup_set(post_ids: set_ids) })))
    expect(import).to be_is_completed
    expect(Favorite.for_user(user.id).order(:created_at).pluck(:post_id)).to eq(ids)
    expect(PostSet.find_by!(creator_id: user.id).post_ids).to eq(set_ids)
    expect(user.reload.user_status.favorite_count).to eq(20_000)
  end
end
