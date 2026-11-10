# frozen_string_literal: true

# Helpers for UserDataImport specs.
module UserDataImportHelpers
  # Inserts a post with an explicit ID (post IDs carry over from the source site), copying a
  # factory post's attributes. Use high IDs so the sequence never hands them out again.
  def insert_post(id, **attrs)
    @post_template ||= create(:post)
    row = @post_template.attributes.except("id", "md5", "change_seq")
                        .merge("id" => id, "md5" => SecureRandom.hex(16)).merge(attrs.transform_keys(&:to_s))
    Post.insert_all!([row])
    Post.find(id)
  end

  # options: favorites/sets (default true), profile/replace_profile (default false), status (default "queued").
  def create_import(user, document, **options)
    UserDataImport.create!(
      user: user, document: document.to_storage, status: options.fetch(:status, "queued"), queued_at: Time.current,
      creator_ip_addr: "127.0.0.1", import_favorites: options.fetch(:favorites, true), import_sets: options.fetch(:sets, true),
      import_profile: options.fetch(:profile, false), replace_profile: options.fetch(:replace_profile, false)
    )
  end

  # Claims and runs an import the way the job does, returning the reloaded record.
  def run_import(import)
    UserDataImportJob.new.perform(import.id)
    import.reload
  end

  def favorite_counts_consistent?(user, post_ids)
    user.reload
    user_ok = user.user_status.favorite_count == Favorite.for_user(user.id).count
    posts_ok = Post.where(id: post_ids).all? { |post| post.fav_count == Favorite.where(post_id: post.id).count }
    user_ok && posts_ok
  end
end

RSpec.configure do |config|
  config.include UserDataImportHelpers
end
