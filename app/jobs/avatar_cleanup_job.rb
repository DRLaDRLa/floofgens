# frozen_string_literal: true

class AvatarCleanupJob < ApplicationJob
  sidekiq_options queue: "default"

  # Sidekiq args are positional JSON; keywords are not an option here.
  def perform(user_id, force = false) # rubocop:disable Style/OptionalBooleanParameter
    user = User.find(user_id)

    # Locked so an avatar can't be published while its files are deleted.
    user.with_lock do
      # A custom image set since this job was queued belongs to the new avatar, so keep it.
      # Forced cleanup is for a destroyed avatar post, and an uploaded image has no post.
      next if user.has_cropped_avatar? && (!force || user.avatar_id.nil?)

      sm = Danbooru.config.storage_manager
      sm.delete_avatar(user_id, "jpg")
      sm.delete_avatar(user_id, "webp")

      if force
        # Atomic so a bit_prefs write made since the find above isn't clobbered.
        flag = User.flag_value_for("has_cropped_avatar")
        User.where(id: user_id).update_all(["bit_prefs = bit_prefs & ~?", flag])
      end
    end
  rescue ActiveRecord::RecordNotFound
    nil
  end
end
