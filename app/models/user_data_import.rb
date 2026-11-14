# frozen_string_literal: true

# A user's restore of an exported data backup (see UserDataImport::Document for the format).
#
# Lifecycle: pending (uploaded, previewed) -> queued (confirmed) -> running -> completed | failed.
# Each user gets one import (unique index on user_id). Until it's confirmed, the upload can be
# cancelled or replaced. A failed import keeps its document so it can always be resumed.
#
# Ownership: a worker claims the row with a random run_token and a lease. Every write
# transaction starts with #fence!, which locks the row and checks the token, so a worker
# that lost its lease can neither write nor change the status. Terminal transitions
# (#complete!, #fail!) are conditional on the same token.
class UserDataImport < ApplicationRecord
  class LeaseLost < StandardError; end

  STATUSES = %w[pending queued running completed failed].freeze
  LEASE_SECONDS = 5.minutes.to_i
  # A queued import whose job hasn't started in this long was most likely lost (Sidekiq OSS
  # doesn't recover jobs from a killed process), so the user may resume it.
  QUEUED_STALE_AFTER = 10.minutes

  belongs_to :user

  validates :status, inclusion: { in: STATUSES }

  STATUSES.each do |name|
    define_method(:"is_#{name}?") { status == name }
  end

  # Claims a queued import, or one whose worker's lease expired. Returns the new run token,
  # or nil when another worker owns it or it isn't claimable. Only one concurrent claimer
  # can match the single conditional UPDATE.
  def self.claim!(id)
    token = SecureRandom.uuid
    claimed = where(id: id)
              .where("status = 'queued' OR (status = 'running' AND lease_expires_at < now())")
              .update_all([<<~SQL.squish, token, LEASE_SECONDS])
                status = 'running', run_token = ?, step = NULL,
                lease_expires_at = now() + make_interval(secs => ?),
                started_at = COALESCE(started_at, now()), updated_at = now()
              SQL
    claimed == 1 ? token : nil
  end

  # The set mapping of the user's import, keeping only sets that still exist and belong to
  # the user. Keys are "<source set id>:<source created_at>"; values are
  # { "post_set_id" => id, "missing" => [post ids that were missing at that import] }.
  def self.restored_sets_for(user)
    merged = {}
    where(user_id: user.id).where.not(set_map: {}).order(:id).pluck(:set_map).each { |map| merged.merge!(map) }
    owned = PostSet.where(id: merged.values.pluck("post_set_id"), creator_id: user.id).pluck(:id).to_set
    merged.select { |_key, entry| owned.include?(entry["post_set_id"]) }
  end

  # Called by DailyPruneJob. Rows that hold a set mapping are never deleted, except for
  # deleted accounts.
  def self.prune!
    where(needs_reindex: true).where("status = 'failed' OR (status = 'running' AND lease_expires_at < now())").find_each do |import|
      Runner.reconcile_index!(import)
    end
    where(status: "pending").where(created_at: ...1.day.ago).where(set_map: {}).delete_all
    # UserDeletion already removes these. This catches an upload that raced the deletion.
    where(id: joins(:user).where(users: { bcrypt_password_hash: UserDeletion::LOCKED_PASSWORD_HASH }).select(:id)).delete_all
  end

  # Must be the first statement of every write transaction. Locks the row (normal favorite and
  # set operations never touch it, so this can't invert their lock order), checks ownership
  # and extends the lease.
  def fence!(token)
    raise ArgumentError, "fence! must run inside a transaction" unless self.class.connection.transaction_open?

    owned = self.class.where(id: id, run_token: token, status: "running").lock("FOR UPDATE").pick(:id)
    raise LeaseLost, "import ##{id} is no longer owned by this worker" unless owned

    self.class.where(id: id).update_all(["lease_expires_at = now() + make_interval(secs => ?), updated_at = now()", LEASE_SECONDS])
  end

  # Records a committed write that needs a post reindex. Called inside the write transaction.
  # Returns the new generation, which #acknowledge_reindex! uses once the reindex is enqueued.
  def record_write!
    self.class.connection.select_value(self.class.sanitize_sql([<<~SQL.squish, id])).to_i
      UPDATE user_data_imports SET needs_reindex = true, reindex_generation = reindex_generation + 1
      WHERE id = ? RETURNING reindex_generation
    SQL
  end

  # Clears needs_reindex if no other write happened since `generation`. A later write bumps the
  # generation, so this can never clear the flag for writes whose reindex wasn't enqueued.
  # Returns the number of rows updated (0 or 1).
  def acknowledge_reindex!(generation, token: nil)
    scope = self.class.where(id: id, reindex_generation: generation)
    scope = scope.where(run_token: token) if token
    scope.update_all(needs_reindex: false)
  end

  # ---------- results ---------- #
  #
  # `results` holds what the results page and the JSON report show. The job fills it in as it
  # goes, so the page can show progress while it runs:
  #
  #   "baseline"  => what the first run set out to do (favorites to add, already present, sets)
  #   "phases"    => { "profile" | "sets" | "favorites" => "done" }; a resumed run skips these
  #   "favorites" => { "imported" => count, "missing" | "busy" | "unavailable" => [post ids] }
  #   "sets"      => { "created" | "merged" | "failed" => { source set id => details } }
  #   "profile"   => what happened to each field and the avatar
  #
  # The helpers below change one key at a time with a single UPDATE instead of loading the
  # record, changing the hash and saving it:
  # - They run inside the same fenced transaction as the writes they describe. If a batch rolls
  #   back, its count goes with it, so a resumed run never counts anything twice.
  # - A save would write back the whole hash, overwriting anything else stored since this copy
  #   was loaded. Changing only the one key leaves the rest alone.

  # Merges each section of `patch` into that section of results, e.g.
  # merge_results!("phases" => { "sets" => "done" }) leaves the other phases in place.
  def merge_results!(patch)
    patch.each do |section, values|
      self.class.where(id: id).update_all([<<~SQL.squish, section.to_s, section.to_s, values.to_json])
        results = jsonb_set(results, ARRAY[?], COALESCE(results -> ?, '{}'::jsonb) || ?::jsonb, true)
      SQL
    end
  end

  # Adds `amount` to results[section][key], creating either if missing. Used for the running
  # favorites count, one batch at a time.
  def increment_result!(section, key, amount)
    self.class.where(id: id).update_all([<<~SQL.squish, section.to_s, section.to_s, key.to_s, section.to_s, key.to_s, amount])
      results = jsonb_set(results, ARRAY[?],
        COALESCE(results -> ?, '{}'::jsonb) || jsonb_build_object(?, COALESCE((results -> ? ->> ?)::bigint, 0) + ?), true)
    SQL
  end

  # Sets results[path...] = value, e.g. put_result!(["sets", "created", 7], {...}) for one set.
  # Every parent must already exist (see Runner#record_baseline).
  def put_result!(path, value)
    self.class.where(id: id).update_all([
      "results = jsonb_set(results, ?::text[], ?::jsonb, true)", "{#{path.join(',')}}", value.to_json,
    ])
  end

  # Records where a source set was restored and which of its posts were still missing.
  def record_set_mapping!(key, post_set_id, missing)
    self.class.where(id: id).update_all([
      "set_map = set_map || jsonb_build_object(?, ?::jsonb)", key, { post_set_id: post_set_id, missing: missing }.to_json,
    ])
  end

  def complete!(token)
    transaction do
      fence!(token)
      self.class.where(id: id).update_all(
        status: "completed", step: nil, document: nil, run_token: nil, lease_expires_at: nil,
        finished_at: Time.current, updated_at: Time.current
      )
    end
  end

  # Only the worker holding `token` can fail the import. A worker that was replaced updates 0
  # rows and leaves the replacement's status alone. Returns the number of rows updated.
  def fail!(token, message)
    self.class.where(id: id, run_token: token, status: "running").update_all(
      status: "failed", step: nil, error_message: message.to_s.truncate(2_000), run_token: nil,
      lease_expires_at: nil, finished_at: Time.current, updated_at: Time.current
    )
  end

  # pending -> queued with the chosen categories. A second submit matches no row (returns 0).
  def confirm!(favorites:, sets:, profile:, replace_profile:)
    self.class.where(id: id, status: "pending").update_all(
      status: "queued", queued_at: Time.current, updated_at: Time.current,
      import_favorites: favorites, import_sets: sets, import_profile: profile, replace_profile: replace_profile && profile
    )
  end

  # Moves a failed, interrupted or lost import back to queued. Refused while the lease is live.
  # Returns the number of rows updated (0 or 1).
  def requeue!
    self.class.where(id: id).where.not(document: nil)
        .where("status = 'failed' OR (status = 'running' AND lease_expires_at < now()) OR (status = 'queued' AND queued_at < ?)",
               QUEUED_STALE_AFTER.ago)
        .update_all(status: "queued", run_token: nil, lease_expires_at: nil, error_message: nil,
                    queued_at: Time.current, finished_at: nil, updated_at: Time.current)
  end

  def lease_expired?
    lease_expires_at.present? && lease_expires_at < Time.current
  end

  def interrupted?
    (is_running? && lease_expired?) || (is_queued? && queued_at.present? && queued_at < QUEUED_STALE_AFTER.ago)
  end

  def resumable?
    document.present? && (is_failed? || interrupted?)
  end

  def selected_categories
    { "profile" => import_profile, "sets" => import_sets, "favorites" => import_favorites }.select { |_k, v| v }.keys
  end

  def phase_done?(phase)
    results.dig("phases", phase) == "done"
  end

  # Whether any run committed data (favorites, sets or profile fields).
  def any_writes?
    reindex_generation > 0 || results.dig("profile", "changed").present?
  end
end
