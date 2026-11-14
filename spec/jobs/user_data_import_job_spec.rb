# frozen_string_literal: true

require "rails_helper"

RSpec.describe UserDataImportJob do
  include_context "without e6ai post ID limits"
  include_context "as admin"

  let(:user) { create(:user, created_at: 2.weeks.ago) }
  let(:post_record) { insert_post(191_001) }
  let(:import) { create_import(user, parse_backup(favorites: { post_record.id => "2026-03-01T10:00:00Z" })) }

  def expire_lease!(record)
    record.update_columns(lease_expires_at: 1.minute.ago)
  end

  it "leaves the import queued while importing is disabled in the config" do
    allow(Danbooru.config.custom_configuration).to receive(:enable_user_data_import?).and_return(false)
    described_class.new.perform(import.id)
    expect(import.reload).to have_attributes(status: "queued", run_token: nil)
    expect(Favorite.where(user_id: user.id)).to be_empty
  end

  describe ".claim!" do
    it "lets only one claimer take a queued import" do
      tokens = [UserDataImport.claim!(import.id), UserDataImport.claim!(import.id)]
      expect(tokens.compact.size).to eq(1)
      expect(import.reload).to have_attributes(status: "running", run_token: tokens.compact.first)
    end

    it "doesn't take over a live lease, but does take over an expired one" do
      first = UserDataImport.claim!(import.id)
      expect(UserDataImport.claim!(import.id)).to be_nil

      expire_lease!(import)
      second = UserDataImport.claim!(import.id)
      expect(second).to be_present
      expect(second).not_to eq(first)
    end

    it "doesn't claim pending, completed or failed imports" do
      %w[pending completed failed].each do |status|
        import.update_columns(status: status)
        expect(UserDataImport.claim!(import.id)).to be_nil
      end
    end
  end

  describe "a worker that lost its lease" do
    let!(:old_token) { UserDataImport.claim!(import.id) }
    let!(:new_token) do
      expire_lease!(import)
      UserDataImport.claim!(import.id)
    end

    it "can't commit a batch" do
      old_runner = UserDataImport::Runner.new(import.reload, token: old_token)
      expect { old_runner.send(:favorites_batch, [[post_record.id, "2026-03-01T10:00:00.000000Z"]]) }
        .to raise_error(UserDataImport::LeaseLost)
      expect(Favorite.where(post_id: post_record.id)).to be_empty
    end

    it "can't fail or complete the import, even after an unrelated error" do
      runner = instance_double(UserDataImport::Runner)
      allow(UserDataImport::Runner).to receive(:new).and_return(runner)
      allow(runner).to receive(:run!).and_raise(RuntimeError, "boom")

      described_class.new.send(:run, import.reload, old_token)
      expect(import.reload).to have_attributes(status: "running", run_token: new_token, error_message: nil)
      expect(import.fail!(old_token, "x")).to eq(0)
      expect { import.complete!(old_token) }.to raise_error(UserDataImport::LeaseLost)
      expect(import.reload.status).to eq("running")
    end

    it "leaves the new worker to finish normally" do
      UserDataImport::Runner.new(import.reload, token: new_token).run!
      expect(import.reload).to have_attributes(status: "completed", run_token: nil, document: nil)
      expect(Favorite.where(post_id: post_record.id).count).to eq(1)
    end
  end

  it "runs once when the job is enqueued twice" do
    described_class.new.perform(import.id)
    described_class.new.perform(import.id)
    expect(import.reload).to be_is_completed
    expect(Favorite.where(post_id: post_record.id).count).to eq(1)
    expect(import.results.dig("favorites", "imported")).to eq(1)
  end

  it "stops without touching the status when the lease is lost mid-run" do
    allow(UserDataImport::Runner).to receive(:new).and_wrap_original do |original, *args, **kwargs|
      original.call(*args, **kwargs).tap do |runner|
        allow(runner).to receive(:run!) do
          UserDataImport.where(id: import.id).update_all(run_token: SecureRandom.uuid) # someone took over
          raise UserDataImport::LeaseLost
        end
      end
    end

    described_class.new.perform(import.id)
    expect(import.reload.status).to eq("running")
  end

  describe "#requeue!" do
    it "refuses while a worker holds a live lease" do
      UserDataImport.claim!(import.id)
      expect(import.reload.requeue!).to eq(0)
      expect(import.reload.status).to eq("running")
    end

    it "requeues an interrupted import" do
      UserDataImport.claim!(import.id)
      expire_lease!(import)
      expect(import.reload).to be_resumable
      expect(import.requeue!).to eq(1)
      expect(import.reload).to have_attributes(status: "queued", run_token: nil)
    end
  end
end
