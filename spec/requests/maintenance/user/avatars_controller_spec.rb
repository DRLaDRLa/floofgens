# frozen_string_literal: true

require "rails_helper"

RSpec.describe Maintenance::User::AvatarsController do
  include_context "as member"
  # ---------------------------------------------------------------------------
  # GET /maintenance/user/avatar/edit
  # ---------------------------------------------------------------------------

  describe "GET /maintenance/user/avatar/edit" do
    context "when anonymous" do
      it "redirects to the login page" do
        get edit_maintenance_user_avatar_path
        expect(response).to redirect_to(new_session_path(url: edit_maintenance_user_avatar_path))
      end
    end

    context "when logged in with no avatar set" do
      let(:user) { create(:user) }

      before { sign_in_as(user) }

      it "redirects back with a notice" do
        get edit_maintenance_user_avatar_path
        expect(response).to redirect_to(settings_users_path)
        expect(flash[:notice]).to eq("Set an avatar post ID in your settings first")
      end
    end

    context "when logged in with an avatar set" do
      let(:user) { create(:user) }
      let(:post) { create(:post) }

      before do
        user.update_columns(avatar_id: post.id)
        sign_in_as(user)
      end

      it "returns 200" do
        get edit_maintenance_user_avatar_path
        expect(response).to have_http_status(:ok)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # PATCH /maintenance/user/avatar
  # ---------------------------------------------------------------------------

  describe "PATCH /maintenance/user/avatar" do
    context "when anonymous" do
      it "redirects to the login page" do
        patch maintenance_user_avatar_path
        expect(response).to redirect_to(new_session_path)
      end
    end

    context "when logged in" do
      let(:user) { create(:user) }
      let(:post) { create(:post) }

      # Factory posts have image_width: 640, image_height: 480 and no sample,
      # so sample_width = 640 and sample_height = 480.
      # small_image_width defaults to 256.
      let(:valid_params) { { avatar_crop_x: 0, avatar_crop_y: 0, avatar_crop_w: 256 } }

      before do
        user.update_columns(avatar_id: post.id)
        sign_in_as(user)
      end

      context "when crop params are missing" do
        it "redirects back with a notice when x is absent" do
          patch maintenance_user_avatar_path, params: { avatar_crop_y: 0, avatar_crop_w: 256 }
          expect(response).to redirect_to(edit_maintenance_user_avatar_path)
          expect(flash[:notice]).to eq("Please draw a crop selection.")
        end

        it "redirects back with a notice when y is absent" do
          patch maintenance_user_avatar_path, params: { avatar_crop_x: 0, avatar_crop_w: 256 }
          expect(response).to redirect_to(edit_maintenance_user_avatar_path)
          expect(flash[:notice]).to eq("Please draw a crop selection.")
        end

        it "redirects back with a notice when w is absent" do
          patch maintenance_user_avatar_path, params: { avatar_crop_x: 0, avatar_crop_y: 0 }
          expect(response).to redirect_to(edit_maintenance_user_avatar_path)
          expect(flash[:notice]).to eq("Please draw a crop selection.")
        end
      end

      context "when the user has no avatar_id" do
        before { user.update_columns(avatar_id: nil) }

        it "redirects back with a notice" do
          patch maintenance_user_avatar_path, params: valid_params
          expect(response).to redirect_to(edit_maintenance_user_avatar_path)
          expect(flash[:notice]).to eq("Set an avatar post ID in your settings first.")
        end
      end

      context "when the avatar post does not exist" do
        before { user.update_columns(avatar_id: 0) }

        it "redirects back with a notice" do
          patch maintenance_user_avatar_path, params: valid_params
          expect(response).to redirect_to(edit_maintenance_user_avatar_path)
          expect(flash[:notice]).to eq("Avatar post not found.")
        end
      end

      context "with invalid crop coordinates" do
        it "rejects w smaller than the minimum" do
          patch maintenance_user_avatar_path, params: { avatar_crop_x: 0, avatar_crop_y: 0, avatar_crop_w: 255 }
          expect(response).to redirect_to(edit_maintenance_user_avatar_path)
          expect(flash[:notice]).to eq("Invalid crop coordinates")
        end

        it "rejects negative x" do
          patch maintenance_user_avatar_path, params: { avatar_crop_x: -1, avatar_crop_y: 0, avatar_crop_w: 256 }
          expect(response).to redirect_to(edit_maintenance_user_avatar_path)
          expect(flash[:notice]).to eq("Invalid crop coordinates")
        end

        it "rejects negative y" do
          patch maintenance_user_avatar_path, params: { avatar_crop_x: 0, avatar_crop_y: -1, avatar_crop_w: 256 }
          expect(response).to redirect_to(edit_maintenance_user_avatar_path)
          expect(flash[:notice]).to eq("Invalid crop coordinates")
        end

        it "rejects a selection that extends past the right edge" do
          # x=400, w=256 → 400+256=656 > 640
          patch maintenance_user_avatar_path, params: { avatar_crop_x: 400, avatar_crop_y: 0, avatar_crop_w: 256 }
          expect(response).to redirect_to(edit_maintenance_user_avatar_path)
          expect(flash[:notice]).to eq("Invalid crop coordinates")
        end

        it "rejects a selection that extends past the bottom edge" do
          # y=300, w=256 → 300+256=556 > 480
          patch maintenance_user_avatar_path, params: { avatar_crop_x: 0, avatar_crop_y: 300, avatar_crop_w: 256 }
          expect(response).to redirect_to(edit_maintenance_user_avatar_path)
          expect(flash[:notice]).to eq("Invalid crop coordinates")
        end
      end

      context "with valid crop params" do
        it "enqueues an AvatarCropJob with the correct arguments" do
          expect do
            patch maintenance_user_avatar_path, params: valid_params
          end.to enqueue_sidekiq_job(AvatarCropJob).with(user.id, post.id, 0, 0, 256)
        end

        it "redirects to the user's profile" do
          patch maintenance_user_avatar_path, params: valid_params
          expect(response).to redirect_to(user_path(user))
        end

        it "sets a processing notice" do
          patch maintenance_user_avatar_path, params: valid_params
          expect(flash[:notice]).to match(/being processed/i)
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # GET /maintenance/user/avatar/new
  # ---------------------------------------------------------------------------

  describe "GET /maintenance/user/avatar/new" do
    context "when anonymous" do
      it "redirects to the login page" do
        get new_maintenance_user_avatar_path
        expect(response).to redirect_to(new_session_path(url: new_maintenance_user_avatar_path))
      end
    end

    context "when logged in" do
      before { sign_in_as(create(:user)) }

      it "returns 200" do
        get new_maintenance_user_avatar_path
        expect(response).to have_http_status(:ok)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # POST /maintenance/user/avatar
  # ---------------------------------------------------------------------------

  describe "POST /maintenance/user/avatar" do
    let(:image) { fixture_file_upload("spec/fixtures/files/sample.jpg", "image/jpeg") }

    context "when anonymous" do
      it "redirects to the login page" do
        post maintenance_user_avatar_path, params: { avatar_file: image }
        expect(response).to redirect_to(new_session_path)
      end
    end

    context "when logged in" do
      let(:user) { create(:user) }

      before do
        sign_in_as(user)
        allow(ImageSampler).to receive(:generate_uploaded_avatar)
      end

      it "stores the image and switches to it" do
        post maintenance_user_avatar_path, params: { avatar_file: image }
        expect(ImageSampler).to have_received(:generate_uploaded_avatar).with(kind_of(String), user.id, crop: nil)
        expect(user.reload.has_uploaded_avatar?).to be true
        expect(response).to redirect_to(user_path(user))
        expect(flash[:notice]).to eq("Avatar updated")
      end

      it "replaces an avatar post" do
        user.update_columns(avatar_id: create(:post).id)
        post maintenance_user_avatar_path, params: { avatar_file: image }
        expect(user.reload.avatar_id).to be_nil
        expect(user.has_uploaded_avatar?).to be true
      end

      it "does not enqueue a cleanup that would delete the new image" do
        user.update_columns(avatar_id: create(:post).id)
        expect do
          post maintenance_user_avatar_path, params: { avatar_file: image }
        end.not_to enqueue_sidekiq_job(AvatarCleanupJob)
      end

      it "uses the center when no selection was drawn" do
        post maintenance_user_avatar_path, params: { avatar_file: image, avatar_crop_x: "", avatar_crop_y: "", avatar_crop_w: "" }
        expect(ImageSampler).to have_received(:generate_uploaded_avatar).with(kind_of(String), user.id, crop: nil)
      end

      context "with a crop selection" do
        before { allow(VipsCommand).to receive(:dimensions).and_return([800, 600]) }

        def upload(left, top, width)
          post maintenance_user_avatar_path, params: { avatar_file: image, avatar_crop_x: left, avatar_crop_y: top, avatar_crop_w: width }
        end

        it "crops the selected square" do
          upload(100, 50, 300)
          expect(ImageSampler).to have_received(:generate_uploaded_avatar).with(kind_of(String), user.id, crop: { x: 100, y: 50, w: 300 })
          expect(response).to redirect_to(user_path(user))
        end

        it "accepts a selection that touches the bottom right corner" do
          upload(200, 0, 600)
          expect(ImageSampler).to have_received(:generate_uploaded_avatar).with(kind_of(String), user.id, crop: { x: 200, y: 0, w: 600 })
        end

        [
          ["smaller than the minimum", [0, 0, 63]],
          ["past the right edge", [600, 0, 201]],
          ["past the bottom edge", [0, 400, 201]],
          ["at a negative position", [-1, 0, 100]],
          ["not a number", ["abc", 0, 100]],
          ["missing a value", [0, 0, ""]],
        ].each do |label, (x, y, w)|
          it "rejects a selection #{label}" do
            upload(x, y, w)
            expect(response).to redirect_to(new_maintenance_user_avatar_path)
            expect(flash[:notice]).to include("Invalid crop selection")
            expect(ImageSampler).not_to have_received(:generate_uploaded_avatar)
          end
        end

        it "allows a small selection when the image itself is small" do
          allow(VipsCommand).to receive(:dimensions).and_return([40, 40])
          upload(0, 0, 40)
          expect(ImageSampler).to have_received(:generate_uploaded_avatar).with(kind_of(String), user.id, crop: { x: 0, y: 0, w: 40 })
        end
      end

      it "rejects a request with no file" do
        post maintenance_user_avatar_path
        expect(response).to redirect_to(new_maintenance_user_avatar_path)
        expect(flash[:notice]).to eq("Choose an image to upload.")
      end

      context "with a large file" do
        let(:limit) { Maintenance::User::AvatarsController::UPLOAD_MAX_FILE_SIZE }
        let(:leeway) { Maintenance::User::AvatarsController::UPLOAD_FILE_SIZE_LEEWAY }

        def upload_of_size(bytes)
          upload = fixture_file_upload("spec/fixtures/files/sample.jpg", "image/jpeg")
          allow(upload).to receive(:size).and_return(bytes)
          allow(ActionDispatch::Http::UploadedFile).to receive(:new).and_wrap_original do |original, *args, **kwargs|
            original.call(*args, **kwargs).tap { |file| allow(file).to receive(:size).and_return(bytes) }
          end
          post maintenance_user_avatar_path, params: { avatar_file: upload }
        end

        it "accepts a file a little over the limit" do
          upload_of_size(limit + leeway)
          expect(ImageSampler).to have_received(:generate_uploaded_avatar)
          expect(response).to redirect_to(user_path(user))
        end

        it "rejects a file past the leeway and says why" do
          upload_of_size(4.1.megabytes.to_i)
          expect(response).to redirect_to(new_maintenance_user_avatar_path)
          expect(flash[:notice]).to eq("That image is 4.1 MB, but avatars can be at most 3 MB. Try a smaller or more compressed version.")
          expect(ImageSampler).not_to have_received(:generate_uploaded_avatar)
        end

        it "rejects a file one byte past the leeway" do
          upload_of_size(limit + leeway + 1)
          expect(flash[:notice]).to include("at most 3 MB")
          expect(ImageSampler).not_to have_received(:generate_uploaded_avatar)
        end
      end

      it "rejects an image with very large dimensions" do
        allow(VipsCommand).to receive(:dimensions).and_return([20_000, 100])
        post maintenance_user_avatar_path, params: { avatar_file: image }
        expect(response).to redirect_to(new_maintenance_user_avatar_path)
        expect(flash[:notice]).to include("pixels wide or tall")
        expect(ImageSampler).not_to have_received(:generate_uploaded_avatar)
      end

      it "rejects a file that is not an image" do
        file = fixture_file_upload("spec/fixtures/files/staff_file.txt", "image/png")
        post maintenance_user_avatar_path, params: { avatar_file: file }
        expect(response).to redirect_to(new_maintenance_user_avatar_path)
        expect(flash[:notice]).to include("isn't supported")
        expect(user.reload.has_uploaded_avatar?).to be false
      end

      it "reports an image that can't be processed" do
        allow(ImageSampler).to receive(:generate_uploaded_avatar).and_raise(VipsCommand::Error, "broken")
        post maintenance_user_avatar_path, params: { avatar_file: image }
        expect(response).to redirect_to(new_maintenance_user_avatar_path)
        expect(flash[:notice]).to include("couldn't be read")
        expect(user.reload.has_uploaded_avatar?).to be false
      end
    end
  end

  # ---------------------------------------------------------------------------
  # DELETE /maintenance/user/avatar
  # ---------------------------------------------------------------------------

  describe "DELETE /maintenance/user/avatar" do
    let(:user) { create(:user) }
    let(:cropped) { User.flag_value_for("has_cropped_avatar") }

    before { sign_in_as(user) }

    it "removes an uploaded avatar" do
      user.update_columns(avatar_id: nil, bit_prefs: user.bit_prefs | cropped)
      expect do
        delete maintenance_user_avatar_path
      end.to enqueue_sidekiq_job(AvatarCleanupJob).with(user.id)
      expect(user.reload.has_avatar?).to be false
      expect(response).to redirect_to(settings_users_path(tab: "profile"))
      expect(flash[:notice]).to eq("Avatar removed")
    end

    it "removes an avatar post" do
      user.update_columns(avatar_id: create(:post).id)
      delete maintenance_user_avatar_path
      expect(user.reload.avatar_id).to be_nil
    end
  end
end
