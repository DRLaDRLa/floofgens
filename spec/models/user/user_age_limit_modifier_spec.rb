# frozen_string_literal: true

require "rails_helper"

RSpec.describe User do
  include_context "as admin"

  let(:user) { create(:user) }

  describe "launch period age limit exemptions" do
    before do
      allow(Danbooru.config.custom_configuration).to receive_messages(disable_age_checks?: false, launch_period_limit_modifiers: [
        [Date.new(2026, 11, 11), ->(_duration) { 0.days }],
        [Date.new(2026, 11, 21), ->(_duration) { 1.day }],
        [Date.new(2026, 12, 1), ->(duration) { duration / 2.0 }],
        [Date.new(2027, 1, 1), nil],
      ])
    end

    describe "#duration_for_creation_date" do
      it "returns the full duration before the exemption period starts" do
        user.update_column(:created_at, Time.zone.parse("2026-11-10 23:59:59"))
        expect(user.duration_for_creation_date(7.days)).to eq(7.days)
      end

      it "returns 0 days during the first tier (Nov 11 - Nov 20, 2026)" do
        [
          Time.zone.parse("2026-11-11 00:00:00"),
          Time.zone.parse("2026-11-15 12:00:00"),
          Time.zone.parse("2026-11-20 23:59:59"),
        ].each do |timestamp|
          user.update_column(:created_at, timestamp)
          expect(user.duration_for_creation_date(7.days)).to eq(0.days)
        end
      end

      it "returns a flat 1 day during the second tier (Nov 21 - Nov 30, 2026)" do
        [
          Time.zone.parse("2026-11-21 00:00:00"),
          Time.zone.parse("2026-11-25 12:00:00"),
          Time.zone.parse("2026-11-30 23:59:59"),
        ].each do |timestamp|
          user.update_column(:created_at, timestamp)
          expect(user.duration_for_creation_date(7.days)).to eq(1.day)
          expect(user.duration_for_creation_date(3.days)).to eq(1.day)
        end
      end

      it "returns half the normal duration during the third tier (Dec 1, 2026 - Dec 31, 2026)" do
        [
          Time.zone.parse("2026-12-01 00:00:00"),
          Time.zone.parse("2026-12-15 12:00:00"),
          Time.zone.parse("2026-12-31 23:59:59"),
        ].each do |timestamp|
          user.update_column(:created_at, timestamp)
          expect(user.duration_for_creation_date(7.days)).to eq(3.5.days)
          expect(user.duration_for_creation_date(3.days)).to eq(1.5.days)
        end
      end

      it "reverts to the full duration once the closing cutoff date is reached (Jan 1, 2027+)" do
        user.update_column(:created_at, Time.zone.parse("2027-01-01 00:00:00"))
        expect(user.duration_for_creation_date(7.days)).to eq(7.days)
      end
    end

    describe "#younger_than and #older_than" do
      it "immediately satisfies age checks in tier 1 (Nov 11 - Nov 20, 2026)" do
        travel_to(Time.zone.parse("2026-11-15 12:05:00")) do
          user.update_column(:created_at, Time.zone.parse("2026-11-15 12:00:00"))

          expect(user.younger_than(7.days)).to be(false)
          expect(user.older_than(7.days)).to be(true)
          expect(user.can_discord?).to be(true)
          expect(user.can_remove_from_pools?).to be(true)
        end
      end

      it "enforces a flat 1-day age check in tier 2 (Nov 21 - Nov 30, 2026)" do
        signup = Time.zone.parse("2026-11-22 12:00:00")
        user.update_column(:created_at, signup)

        travel_to(signup + 23.hours) do
          expect(user.younger_than(7.days)).to be(true)
          expect(user.older_than(7.days)).to be(false)
          expect(user.can_discord?).to be(false)
        end

        travel_to(signup + 25.hours) do
          expect(user.younger_than(7.days)).to be(false)
          expect(user.older_than(7.days)).to be(true)
          expect(user.can_discord?).to be(true)
        end
      end

      it "enforces half the normal duration in tier 3 (Dec 1, 2026 - Dec 31, 2026)" do
        signup = Time.zone.parse("2026-12-10 12:00:00")
        user.update_column(:created_at, signup)

        travel_to(signup + 3.days) do
          expect(user.younger_than(7.days)).to be(true)
          expect(user.older_than(7.days)).to be(false)
          expect(user.can_discord?).to be(false)
        end

        travel_to(signup + 4.days) do
          expect(user.younger_than(7.days)).to be(false)
          expect(user.older_than(7.days)).to be(true)
          expect(user.can_discord?).to be(true)
        end
      end

      it "enforces the full duration after the exemption period ends (Jan 1, 2027+)" do
        signup = Time.zone.parse("2027-01-01 12:00:00")
        user.update_column(:created_at, signup)

        travel_to(signup + 6.days) do
          expect(user.younger_than(7.days)).to be(true)
          expect(user.older_than(7.days)).to be(false)
          expect(user.can_discord?).to be(false)
        end

        travel_to(signup + 8.days) do
          expect(user.younger_than(7.days)).to be(false)
          expect(user.older_than(7.days)).to be(true)
          expect(user.can_discord?).to be(true)
        end
      end
    end
  end
end
