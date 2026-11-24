# frozen_string_literal: true

module Maintenance
  module User
    class AvatarsController < ApplicationController
      before_action :member_only

      # The advertised limit. Files a little over it are still accepted, so an image that
      # rounds to "3 MB" on the user's computer isn't turned away.
      UPLOAD_MAX_FILE_SIZE = 3.megabytes
      UPLOAD_FILE_SIZE_LEEWAY = 0.2.megabytes.to_i
      UPLOAD_MAX_DIMENSION = 10_000
      UPLOAD_MIN_CROP = 64
      UPLOAD_LIMIT = 10
      UPLOAD_PERIOD = 1.hour

      def new
      end

      def edit
        unless CurrentUser.user.avatar_id
          flash[:notice] = "Set an avatar post ID in your settings first"
          redirect_to settings_users_path and return
        end

        @post = Post.find_by(id: CurrentUser.user.avatar_id)

        raise ActiveRecord::RecordNotFound, "Avatar post not found." unless @post
        raise ::User::PrivilegeError, "You do not have permission to edit this avatar." if @post.deleteblocked? || @post.safeblocked? || @post.siteblocked?
        raise ::User::PrivilegeError, "Flash is not supported as an avatar." if @post.is_flash?
      end

      def create
        raise APIThrottled if RateLimiter.throttle!("avatar_upload:#{CurrentUser.id}", limit: UPLOAD_LIMIT, period: UPLOAD_PERIOD)

        file = params[:avatar_file]
        return upload_error("Choose an image to upload.") unless file.respond_to?(:path) && file.respond_to?(:size)
        if file.size > UPLOAD_MAX_FILE_SIZE + UPLOAD_FILE_SIZE_LEEWAY
          size = (file.size.to_f / 1.megabyte).round(1)
          return upload_error("That image is #{size} MB, but avatars can be at most #{UPLOAD_MAX_FILE_SIZE / 1.megabyte} MB. Try a smaller or more compressed version.")
        end

        width, height = VipsCommand.dimensions(file.path)
        if width > UPLOAD_MAX_DIMENSION || height > UPLOAD_MAX_DIMENSION
          return upload_error("The image can be at most #{UPLOAD_MAX_DIMENSION} pixels wide or tall.")
        end

        crop = upload_crop
        unless crop == :none || valid_upload_crop?(crop, width, height)
          return upload_error("Invalid crop selection. Draw it again, or leave it empty to use the center of the image.")
        end

        ImageSampler.generate_uploaded_avatar(file.path, CurrentUser.id, crop: crop == :none ? nil : crop)
        CurrentUser.user.use_uploaded_avatar!

        flash[:notice] = "Avatar updated"
        redirect_to user_path(CurrentUser.user)
      rescue VipsCommand::UnsupportedFormat
        upload_error("That file type isn't supported. Upload a JPEG, PNG, GIF, or WebP image.")
      rescue VipsCommand::Error
        upload_error("That image couldn't be read. Try saving it again or using a different file.")
      end

      def update
        x = params[:avatar_crop_x].presence
        y = params[:avatar_crop_y].presence
        w = params[:avatar_crop_w].presence

        unless x && y && w
          flash[:notice] = "Please draw a crop selection."
          redirect_to edit_maintenance_user_avatar_path and return
        end

        x, y, w = [x, y, w].map(&:to_i)
        post_id = CurrentUser.user.avatar_id

        unless post_id
          flash[:notice] = "Set an avatar post ID in your settings first."
          redirect_to edit_maintenance_user_avatar_path and return
        end

        post = Post.find_by(id: post_id)
        unless post
          flash[:notice] = "Avatar post not found."
          redirect_to edit_maintenance_user_avatar_path and return
        end

        if post.deleteblocked? || post.safeblocked? || post.siteblocked?
          flash[:notice] = "You do not have permission to edit this avatar."
          redirect_to edit_maintenance_user_avatar_path and return
        end

        if post.is_flash?
          flash[:notice] = "Flash is not supported as an avatar."
          redirect_to edit_maintenance_user_avatar_path and return
        end

        min = Danbooru.config.small_image_width
        source_w = post.sample_width
        source_h = post.sample_height

        unless w >= min && x >= 0 && y >= 0 && x + w <= source_w && y + w <= source_h
          flash[:notice] = "Invalid crop coordinates"
          redirect_to edit_maintenance_user_avatar_path and return
        end

        AvatarCropJob.perform_async(CurrentUser.id, post_id, x, y, w)
        flash[:notice] = "Crop is being processed. It may take a few minutes to complete"
        redirect_to user_path(CurrentUser.user)
      end

      def destroy
        CurrentUser.user.remove_avatar!
        flash[:notice] = "Avatar removed"
        redirect_to settings_users_path(tab: "profile")
      end

      private

      # :none when no selection was drawn, which crops around the centre.
      # Otherwise { x:, y:, w: }, with nil for any value that is missing or not a whole number.
      def upload_crop
        values = %i[x y w].index_with { |key| params[:"avatar_crop_#{key}"].presence }
        return :none if values.values.all?(&:nil?)

        values.transform_values { |value| value.is_a?(String) ? Integer(value, 10, exception: false) : nil }
      end

      # The selection is a square in the image as displayed, at least UPLOAD_MIN_CROP pixels
      # wide unless the image itself is smaller.
      def valid_upload_crop?(crop, width, height)
        x, y, w = crop.values_at(:x, :y, :w)
        return false if [x, y, w].any?(&:nil?)

        min = [UPLOAD_MIN_CROP, width, height].min
        w >= min && x >= 0 && y >= 0 && x + w <= width && y + w <= height
      end

      def upload_error(message)
        flash[:notice] = message
        redirect_to new_maintenance_user_avatar_path
      end
    end
  end
end
