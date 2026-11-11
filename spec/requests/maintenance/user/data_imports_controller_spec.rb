# frozen_string_literal: true

require "rails_helper"

RSpec.describe Maintenance::User::DataImportsController do
  include_context "as admin"

  let(:user) { create(:user, created_at: 2.weeks.ago) }
  let(:time) { "2026-03-01T10:00:00Z" }

  def upload(content, filename: "backup.json")
    file = Tempfile.new(["backup", ".json"])
    file.binmode
    file.write(content)
    file.rewind
    post maintenance_user_data_imports_path, params: { file: Rack::Test::UploadedFile.new(file.path, "application/json", original_filename: filename) }
  end

  def row_counts
    [UserDataImport.count, Favorite.count, PostSet.count]
  end

  before { allow(RateLimiter).to receive(:throttle!).and_return(false) }

  describe "authentication" do
    it "redirects anonymous users to the login page" do
      get new_maintenance_user_data_import_path
      expect(response).to redirect_to(new_session_path(url: new_maintenance_user_data_import_path))
    end

    it "rejects API key authentication" do
      sign_in_as(user)
      allow(CurrentUser).to receive(:api_key).and_return(instance_double(ApiKey))
      get new_maintenance_user_data_import_path
      expect(response).to have_http_status(:forbidden)
    end

    it "doesn't show another user's import" do
      import = create_import(create(:user), parse_backup, status: "pending")
      sign_in_as(user)
      get maintenance_user_data_import_path(import)
      expect(response).to have_http_status(:not_found)
    end
  end

  context "when logged in" do
    before { sign_in_as(user) }

    it "shows the upload form and the settings entry" do
      get new_maintenance_user_data_import_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Upload and preview")

      get settings_users_path
      expect(response.body).to include("Import User Data")
    end

    describe "upload" do
      it "stores a valid backup as a pending import with a preview" do
        post_record = insert_post(903_001)
        upload(backup_json(favorites: { post_record.id => time, 903_099 => time }))

        import = UserDataImport.last
        expect(response).to redirect_to(maintenance_user_data_import_path(import))
        expect(import).to have_attributes(status: "pending", user_id: user.id, file_name: "backup.json")
        expect(import.preview["favorites"]).to include("new" => 1, "missing_count" => 1, "missing" => [903_099])

        get maintenance_user_data_import_path(import)
        expect(response.body).to include("Start import")
      end

      it "accepts a backup larger than the 4 MB cap on non-multipart request bodies" do
        json = backup_json
        upload("#{json}#{' ' * (5.megabytes - json.bytesize)}")
        expect(response).to redirect_to(maintenance_user_data_import_path(UserDataImport.last))
      end

      it "rejects an invalid file without writing anything" do
        expect { upload("{not json") }.not_to(change { row_counts })
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include("isn&#39;t valid JSON")
      end

      it "rejects a file over the size limit before reading it, without writing anything" do
        allow(UserDataImport::Document).to receive(:parse).and_call_original
        expect { upload(" " * (UserDataImport::Document::MAX_FILE_SIZE + 1)) }.not_to(change { row_counts })
        expect(UserDataImport::Document).not_to have_received(:parse)
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include("larger than the 32 MB limit")
      end

      it "rejects a backup over a count limit without writing anything" do
        sets = (1..76).index_with { |id| backup_set(name: "Set #{id}", short_name: "set_#{id}") }
        expect { upload(backup_json(sets: sets)) }.not_to(change { row_counts })
        expect(response.body).to include("sets: 76 sets, the maximum is 75")
      end

      it "replaces a pending import, but not one that's running" do
        first = create_import(user, parse_backup, status: "pending")
        upload(backup_json)
        expect(UserDataImport.where(id: first.id)).to be_empty

        running = UserDataImport.last.tap { |import| import.update_columns(status: "running") }
        expect { upload(backup_json) }.not_to(change(UserDataImport, :count))
        expect(response).to redirect_to(maintenance_user_data_import_path(running))
      end

      it "rate limits uploads per user, not per import" do
        allow(RateLimiter).to receive(:throttle!).with("user_data_import_upload:#{user.id}", limit: 10, period: 1.hour).and_return(true)
        upload(backup_json)
        expect(response).to have_http_status(:too_many_requests)

        sign_in_as(create(:user))
        upload(backup_json)
        expect(response).to have_http_status(:redirect)
      end
    end

    describe "confirm" do
      let(:post_record) { insert_post(903_101) }
      let!(:import) do
        upload(backup_json(favorites: { post_record.id => time }, sets: { 1 => backup_set(post_ids: [post_record.id]) }))
        UserDataImport.last
      end

      it "queues the import once" do
        post confirm_maintenance_user_data_import_path(import), params: { import: { favorites: "1", sets: "1" } }
        post confirm_maintenance_user_data_import_path(import), params: { import: { favorites: "1", sets: "1" } }

        expect(import.reload).to have_attributes(status: "queued", import_favorites: true, import_sets: true, import_profile: false)
        expect(UserDataImportJob.jobs.size).to eq(1)
      end

      it "requires choosing something" do
        post confirm_maintenance_user_data_import_path(import), params: { import: { favorites: "0" } }
        expect(response).to have_http_status(:unprocessable_content)
        expect(import.reload.status).to eq("pending")
      end

      it "refuses a category in conflict, but allows the other one" do
        stub_const("PostSet::MAX_SETS_PER_USER", 1)
        create(:post_set, creator: user) # the account is now full
        post confirm_maintenance_user_data_import_path(import), params: { import: { favorites: "1", sets: "1" } }
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include("would exceed the limit of 1 sets")
        expect(UserDataImportJob.jobs).to be_empty

        post confirm_maintenance_user_data_import_path(import), params: { import: { favorites: "1" } }
        expect(import.reload).to have_attributes(status: "queued", import_sets: false)
      end

      it "checks the per-user run rate limit before doing any work" do
        allow(RateLimiter).to receive(:throttle!).with("user_data_import_run:#{user.id}", limit: 5, period: 1.day).and_return(true)
        allow(UserDataImport::Runner).to receive(:new).and_call_original
        post confirm_maintenance_user_data_import_path(import), params: { import: { favorites: "1" } }
        expect(response).to have_http_status(:too_many_requests)
        expect(UserDataImport::Runner).not_to have_received(:new)
        expect(import.reload.status).to eq("pending")
      end

      it "runs and shows the results" do
        post confirm_maintenance_user_data_import_path(import), params: { import: { favorites: "1", sets: "1" } }
        UserDataImportJob.drain

        get maintenance_user_data_import_path(import)
        expect(response.body).to include("Import finished.")
        get maintenance_user_data_import_path(import, format: :json)
        expect(response.parsed_body).to include("status" => "completed")
        expect(response.parsed_body.dig("results", "favorites", "imported")).to eq(1)
      end
    end

    it "cancels a pending import" do
      import = create_import(user, parse_backup, status: "pending")
      delete maintenance_user_data_import_path(import)
      expect(UserDataImport.where(id: import.id)).to be_empty
    end

    describe "resume" do
      let(:import) { create_import(user, parse_backup, status: "failed") }

      it "requeues a failed import" do
        post resume_maintenance_user_data_import_path(import)
        expect(import.reload.status).to eq("queued")
        expect(UserDataImportJob.jobs.size).to eq(1)
      end

      it "asks to finish the other import first while one is open" do
        other = create_import(user, parse_backup, status: "pending")
        get maintenance_user_data_import_path(import)
        expect(response.body).to include("Finish or cancel your current import first.")
        expect(response.body).not_to include("Resume import")

        post resume_maintenance_user_data_import_path(import)
        expect(response).to redirect_to(maintenance_user_data_import_path(other))
        expect(import.reload.status).to eq("failed")
      end

      it "handles losing the race to the open-import index gracefully" do
        allow_any_instance_of(UserDataImport).to receive(:requeue!).and_return(false) # rubocop:disable RSpec/AnyInstance
        post resume_maintenance_user_data_import_path(import)
        expect(response).to redirect_to(maintenance_user_data_import_path(import))
        expect(flash[:notice]).to include("can't be resumed right now")
      end

      it "asks for the backup again once its document was pruned" do
        import.update_columns(document: nil)
        get maintenance_user_data_import_path(import)
        expect(response.body).to include("This backup is no longer stored.")
        expect(response.body).not_to include("Resume import")

        post resume_maintenance_user_data_import_path(import)
        expect(response).to redirect_to(new_maintenance_user_data_import_path)
        expect(import.reload.status).to eq("failed")
      end

      it "refuses while a worker holds a live lease" do
        import.update_columns(status: "running", run_token: SecureRandom.uuid, lease_expires_at: 5.minutes.from_now)
        post resume_maintenance_user_data_import_path(import)
        expect(flash[:notice]).to eq("This import can't be resumed right now.")
        expect(import.reload.status).to eq("running")
      end
    end
  end
end
