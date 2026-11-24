# frozen_string_literal: true

class AvatarComponent < ViewComponent::Base
  include DeferredPosts
  with_collection_parameter :user

  def initialize(user:)
    super()
    @user = user
    @post_id = user&.avatar_id

    deferred_post_ids.add(@post_id) if @post_id
  end

  def render?
    return false if user.blank?
    true
  end

  private

  attr_reader :user, :post_id

  def article_attributes
    klass = %w[thumbnail avatar no-stats placeholder]
    klass << "no-render" unless user.has_avatar?

    data = {
      "id": post_id,
      "initial": (user.name.presence || "?")[0].upcase,
      "user-id": user.id,
      "user-hash": user.updated_at.to_i,
      "has-cropped-avatar": user.has_cropped_avatar?,
    }
    data.merge!(uploaded_avatar_urls) if user.has_uploaded_avatar?

    {
      class: klass.join(" "),
      data: data,
    }
  end

  # There is no post to take the URL from, so the client gets it from here.
  def uploaded_avatar_urls
    sm = Danbooru.config.storage_manager
    timestamp = user.updated_at.to_i
    {
      "avatar-jpg": sm.avatar_url(user.id, "jpg", timestamp: timestamp),
      "avatar-webp": sm.avatar_url(user.id, "webp", timestamp: timestamp),
    }
  end
end
