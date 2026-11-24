# frozen_string_literal: true

class AvatarCropJob < ApplicationJob
  sidekiq_options queue: "default"

  def perform(user_id, post_id, pos_x, pos_y, width)
    user = User.find(user_id)
    return unless user.avatar_id == post_id

    post = Post.find(post_id)

    # Locked so an upload, removal or cleanup can't run in between. Checked again under the
    # lock, because a crop for an avatar that has since changed or been cleared would replace
    # the current image.
    user.with_lock do
      next unless user.avatar_id == post_id

      ImageSampler.generate_avatar_crop(post, user_id, pos_x: pos_x, pos_y: pos_y, width: width)

      flag = User.flag_value_for("has_cropped_avatar")
      # updated_at changes the avatar URL, so the old image isn't served from cache
      user.update_columns(bit_prefs: user.bit_prefs | flag, updated_at: Time.current)
    end
    UserAvatarUrlCache.invalidate(user_id)
  rescue ActiveRecord::RecordNotFound
    nil
  end
end
