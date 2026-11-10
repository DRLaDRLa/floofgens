# frozen_string_literal: true

module Maintenance
  module User
    # Restores favorites, sets and profile fields from a data backup exported by an
    # e621ng-based site. Upload -> preview -> confirm -> background job -> results.
    class DataImportsController < ApplicationController
      respond_to :html, :json
      before_action :member_only
      before_action :reject_api_key_auth
      before_action :reject_bearer_auth
      before_action :load_import, only: %i[show destroy confirm resume]

      # Per user, not per import record.
      UPLOAD_LIMIT = 10
      UPLOAD_PERIOD = 1.hour
      RUN_LIMIT = 5
      RUN_PERIOD = 1.day

      BUSY_MESSAGE = "Finish or cancel your current import first."
      REUPLOAD_MESSAGE = "This backup is no longer stored. Upload it again to continue; " \
                         "anything already restored will be recognized and not duplicated."

      def show
        respond_with(@import) do |format|
          format.json { render json: report_json }
        end
      end

      def new
        open_import = UserDataImport.unfinished.find_by(user_id: CurrentUser.id)
        redirect_to maintenance_user_data_import_path(open_import), notice: BUSY_MESSAGE if open_import
      end

      def create
        raise APIThrottled if RateLimiter.throttle!("user_data_import_upload:#{CurrentUser.id}", limit: UPLOAD_LIMIT, period: UPLOAD_PERIOD)

        running = UserDataImport.unfinished.where(user_id: CurrentUser.id).where.not(status: "pending").first
        return redirect_to(maintenance_user_data_import_path(running), notice: BUSY_MESSAGE) if running

        file = params[:file]
        return render_upload_errors(["Choose a backup file to upload."]) unless file.respond_to?(:read) && file.respond_to?(:size)
        if file.size > UserDataImport::Document::MAX_FILE_SIZE
          return render_upload_errors(["The file is larger than the #{UserDataImport::Document::MAX_FILE_SIZE / 1.megabyte} MB limit."])
        end

        document = UserDataImport::Document.parse(file.read(UserDataImport::Document::MAX_FILE_SIZE + 1).to_s)
        draft = UserDataImport.new(user: CurrentUser.user)
        plan = UserDataImport::Runner.new(draft, document: document).preflight

        import = UserDataImport.transaction do
          UserDataImport.where(user_id: CurrentUser.id, status: "pending").delete_all
          UserDataImport.create!(
            user: CurrentUser.user, document: document.to_storage, preview: UserDataImport::Runner.preview_from(plan),
            creator_ip_addr: CurrentUser.ip_addr, file_name: file.try(:original_filename).to_s.truncate(255), file_size: file.size
          )
        end
        redirect_to maintenance_user_data_import_path(import)
      rescue UserDataImport::Document::Invalid => e
        render_upload_errors(e.errors)
      rescue ActiveRecord::RecordNotUnique
        redirect_to new_maintenance_user_data_import_path, notice: BUSY_MESSAGE
      end

      def destroy
        if @import.is_pending?
          @import.destroy!
          redirect_to new_maintenance_user_data_import_path, notice: "Import cancelled."
        else
          redirect_to maintenance_user_data_import_path(@import), notice: "Only an import that hasn't started can be cancelled."
        end
      end

      def confirm
        return redirect_to(maintenance_user_data_import_path(@import), notice: "This import has already started.") unless @import.is_pending?

        choice = selected_categories
        return render_confirm_error("Choose at least one thing to restore.") if choice.values_at(:favorites, :sets, :profile).none?

        plan = UserDataImport::Runner.new(@import).preflight
        @import.update_columns(preview: UserDataImport::Runner.preview_from(plan))
        conflicts = UserDataImport::Runner.conflicts_for(plan, choice.select { |k, v| v && k != :replace_profile }.keys.map(&:to_s))
        return render_confirm_error(conflicts.values.join(" ")) if conflicts.any?

        raise APIThrottled if RateLimiter.throttle!("user_data_import_run:#{CurrentUser.id}", limit: RUN_LIMIT, period: RUN_PERIOD)

        UserDataImportJob.perform_async(@import.id) if @import.confirm!(**choice) == 1
        redirect_to maintenance_user_data_import_path(@import)
      rescue UserDataImport::Document::Invalid => e
        render_confirm_error("The stored backup is no longer valid: #{e.message}")
      end

      def resume
        if @import.needs_reupload?
          redirect_to new_maintenance_user_data_import_path, notice: REUPLOAD_MESSAGE
        elsif (other = @import.other_open_import)
          redirect_to maintenance_user_data_import_path(other), notice: BUSY_MESSAGE
        elsif !@import.resumable?
          redirect_to maintenance_user_data_import_path(@import), notice: "This import can't be resumed right now."
        else
          raise APIThrottled if RateLimiter.throttle!("user_data_import_run:#{CurrentUser.id}", limit: RUN_LIMIT, period: RUN_PERIOD)

          if @import.requeue!
            UserDataImportJob.perform_async(@import.id)
            redirect_to maintenance_user_data_import_path(@import), notice: "Import resumed."
          else
            # Lost a race: another import opened, or the worker came back.
            redirect_to maintenance_user_data_import_path(@import), notice: "This import can't be resumed right now. #{BUSY_MESSAGE}"
          end
        end
      end

      private

      def load_import
        @import = UserDataImport.where(user_id: CurrentUser.id).find(params.expect(:id))
      end

      def selected_categories
        values = params.fetch(:import, {}).permit(:favorites, :sets, :profile, :replace_profile)
        cast = ->(key) { ActiveModel::Type::Boolean.new.cast(values[key]) == true }
        { favorites: cast.call(:favorites), sets: cast.call(:sets), profile: cast.call(:profile), replace_profile: cast.call(:replace_profile) }
      end

      def render_upload_errors(errors)
        @errors = errors
        respond_to do |format|
          format.html { render :new, status: 422 }
          format.json { render json: { success: false, errors: errors }, status: 422 }
        end
      end

      def render_confirm_error(message)
        @import.reload
        @confirm_error = message
        respond_to do |format|
          format.html { render :show, status: 422 }
          format.json { render json: { success: false, reason: message }, status: 422 }
        end
      end

      def report_json
        @import.as_json(only: %i[id status error_message import_favorites import_sets import_profile replace_profile
                                 file_name created_at queued_at started_at finished_at]).merge(
                                   "preview" => @import.preview, "results" => @import.results,
                                 )
      end
    end
  end
end
