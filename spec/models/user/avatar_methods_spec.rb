# frozen_string_literal: true

require "rails_helper"

RSpec.describe User do
  include_context "as member"

  let(:user) { create(:user) }
  let(:avatar_post) { create(:post) }
  let(:cropped) { User.flag_value_for("has_cropped_avatar") }

  def give_uploaded_avatar(target = user)
    target.update_columns(avatar_id: nil, bit_prefs: target.bit_prefs | cropped)
  end

  describe "#has_uploaded_avatar?" do
    it "is false with no avatar" do
      expect(user.has_uploaded_avatar?).to be false
    end

    it "is false for a cropped avatar post" do
      user.update_columns(avatar_id: avatar_post.id, bit_prefs: user.bit_prefs | cropped)
      expect(user.has_uploaded_avatar?).to be false
    end

    it "is true for an avatar image with no post" do
      give_uploaded_avatar
      expect(user.has_uploaded_avatar?).to be true
    end
  end

  describe "#has_avatar?" do
    it "is false with no avatar" do
      expect(user.has_avatar?).to be false
    end

    it "is true with an avatar post" do
      user.update_columns(avatar_id: avatar_post.id)
      expect(user.has_avatar?).to be true
    end

    it "is true with an uploaded avatar" do
      give_uploaded_avatar
      expect(user.has_avatar?).to be true
    end
  end

  describe "#use_uploaded_avatar!" do
    let(:storage) { instance_spy(StorageManager) }
    let(:files) { { "jpg" => instance_double(Tempfile), "webp" => instance_double(Tempfile) } }

    before { allow(Danbooru.config.custom_configuration).to receive(:storage_manager).and_return(storage) }

    it "stores the image files" do
      user.use_uploaded_avatar!(files)
      expect(storage).to have_received(:store_avatar).with(files["jpg"], user.id, "jpg")
      expect(storage).to have_received(:store_avatar).with(files["webp"], user.id, "webp")
    end

    it "clears the avatar post and sets the image flag" do
      user.update_columns(avatar_id: avatar_post.id)
      user.use_uploaded_avatar!(files)
      expect(user.avatar_id).to be_nil
      expect(user.has_cropped_avatar?).to be true
    end

    it "keeps the other flags" do
      other = User.flag_value_for("can_approve_posts")
      user.update_columns(bit_prefs: other)
      user.use_uploaded_avatar!(files)
      expect(user.can_approve_posts?).to be true
    end

    it "does not enqueue a cleanup" do
      user.update_columns(avatar_id: avatar_post.id, bit_prefs: user.bit_prefs | cropped)
      expect { user.use_uploaded_avatar!(files) }.not_to enqueue_sidekiq_job(AvatarCleanupJob)
    end

    it "invalidates the avatar URL cache" do
      allow(UserAvatarUrlCache).to receive(:invalidate)
      user.use_uploaded_avatar!(files)
      expect(UserAvatarUrlCache).to have_received(:invalidate).with(user.id)
    end
  end

  describe "changing the avatar post" do
    it "clears an image uploaded after this copy of the user was loaded" do
      stale = User.find(user.id)
      give_uploaded_avatar
      expect { stale.update!(avatar_id: avatar_post.id) }.to enqueue_sidekiq_job(AvatarCleanupJob).with(user.id)
      expect(user.reload).to have_attributes(avatar_id: avatar_post.id, has_cropped_avatar?: false)
    end

    it "clears a cropped avatar" do
      user.update_columns(avatar_id: avatar_post.id, bit_prefs: user.bit_prefs | cropped)
      expect { user.update!(avatar_id: create(:post).id) }.to enqueue_sidekiq_job(AvatarCleanupJob).with(user.id)
      expect(user.has_cropped_avatar?).to be false
      expect(user.reload.has_cropped_avatar?).to be false
    end
  end

  describe "#remove_avatar!" do
    it "clears an uploaded avatar and deletes the image" do
      give_uploaded_avatar
      expect { user.remove_avatar! }.to enqueue_sidekiq_job(AvatarCleanupJob).with(user.id)
      expect(user.has_avatar?).to be false
    end

    it "clears an avatar post" do
      user.update_columns(avatar_id: avatar_post.id)
      user.remove_avatar!
      expect(user.reload.avatar_id).to be_nil
    end

    it "clears a cropped avatar post and deletes the image" do
      user.update_columns(avatar_id: avatar_post.id, bit_prefs: user.bit_prefs | cropped)
      expect { user.remove_avatar! }.to enqueue_sidekiq_job(AvatarCleanupJob).with(user.id)
      expect(user.reload.has_avatar?).to be false
    end

    it "does nothing without an avatar" do
      expect { user.remove_avatar! }.not_to enqueue_sidekiq_job(AvatarCleanupJob)
    end
  end
end
