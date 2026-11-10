# frozen_string_literal: true

# Runs a confirmed UserDataImport. Ownership is decided by UserDataImport.claim! and enforced by
# the fence in every write, not by the Sidekiq lock, which only cuts down duplicate enqueues
# (a killed process can leave it released or expired).
class UserDataImportJob < ApplicationJob
  sidekiq_options queue: "low_prio", retry: 0, lock: :until_executing, lock_ttl: 1.hour.to_i

  def perform(import_id)
    token = UserDataImport.claim!(import_id)
    return if token.nil? # not queued, or another worker holds a live lease

    run(UserDataImport.find(import_id), token)
  end

  private

  def run(import, token)
    UserDataImport::Runner.new(import, token: token).run!
  rescue UserDataImport::LeaseLost => e
    # Another worker took over after our lease expired. It owns the status now.
    DanbooruLogger.log(e, expected: true)
  rescue StandardError => e
    # Not Exception: Sidekiq::Shutdown must propagate; the lease then expires and the
    # import can be resumed.
    DanbooruLogger.log(e, expected: expected?(e))
    import.fail!(token, failure_message(import, e))
  end

  def expected?(error)
    error.is_a?(UserDataImport::Runner::CapacityExceeded) || error.is_a?(UserDataImport::Runner::Conflict) ||
      error.is_a?(UserDataImport::Document::Invalid)
  end

  def failure_message(import, error)
    reason = expected?(error) ? error.message : "Something went wrong on our side (#{error.class.name})."
    import.reload
    if import.any_writes?
      "Partially restored: #{UserDataImport::Runner.progress_summary(import)}. #{reason}"
    else
      "Nothing was imported. #{reason}"
    end
  end
end
