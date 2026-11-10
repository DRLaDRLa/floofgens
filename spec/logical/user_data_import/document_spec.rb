# frozen_string_literal: true

require "rails_helper"

RSpec.describe UserDataImport::Document do
  let(:time) { "2026-03-01T10:00:00Z" }

  def errors_for(raw)
    described_class.parse(raw)
    raise "expected the backup to be rejected"
  rescue described_class::Invalid => e
    e.errors
  end

  def errors_for_backup(...)
    errors_for(backup_json(...))
  end

  def errors_for_hash(hash)
    errors_for(hash.to_json)
  end

  describe "valid backups" do
    it "parses the exporter's format" do
      raw = file_fixture("user_data_export_v1.json").read
      document = described_class.parse(raw)

      expect(document.favorites.map(&:post_id)).to eq([456, 123, 789])
      expect(document.sets.map(&:source_id)).to eq([7, 42])
      expect(document.sets.last.post_ids).to eq([789, 101, 5])
      expect(document.profile).to eq(about: "About me", artinfo: "Commissions open", avatar: { post_id: 123, cropped: true })
    end

    it "accepts an empty export" do
      document = parse_backup
      expect(document).to be_empty
      expect(document.referenced_post_ids).to eq([])
    end

    it "orders favorites by timestamp, breaking ties with the file order" do
      document = parse_backup(favorites: { "900" => time, "12" => time, "450" => time, "5" => "2026-01-01T00:00:00Z" })
      expect(document.favorites.map(&:post_id)).to eq([5, 900, 12, 450])
    end

    it "keeps the file order through storage, where jsonb sorts object keys" do
      document = parse_backup(favorites: { "900" => time, "12" => time, "450" => time })
      stored = JSON.parse(document.to_storage.to_json)
      stored["favorites"] = stored["favorites"].sort.to_h # what jsonb does to key order

      expect(described_class.from_storage(stored).favorites.map(&:post_id)).to eq([900, 12, 450])
    end
  end

  describe "size and count limits" do
    it "accepts a file of exactly the byte limit and rejects one byte more, before parsing" do
      base = backup_json
      exact = "#{base}#{' ' * (described_class::MAX_FILE_SIZE - base.bytesize)}"
      expect { described_class.parse(exact) }.not_to raise_error

      allow(JSON).to receive(:parse).and_call_original
      expect(errors_for("#{exact} ")).to include(include("larger than the 32 MB limit"))
      expect(JSON).not_to have_received(:parse)
    end

    it "accepts exactly the maximum number of favorites and rejects one more" do
      max = described_class.max_favorites
      expect(max).to eq(200_000)
      favorites = (1..max).to_h { |id| [id.to_s, time] }
      expect(parse_backup(favorites: favorites).favorites.size).to eq(max)

      favorites[(max + 1).to_s] = time
      expect(errors_for_backup(favorites: favorites)).to eq(["favorites: 200001 favorites, the maximum is 200000"])
    end

    it "accepts exactly 75 sets and rejects 76" do
      sets = (1..75).index_with { |id| backup_set(name: "Set #{id}", short_name: "set_#{id}") }
      expect(parse_backup(sets: sets).sets.size).to eq(75)

      sets[76] = backup_set(name: "Set 76", short_name: "set_76")
      expect(errors_for_backup(sets: sets)).to eq(["sets: 76 sets, the maximum is 75"])
    end

    it "accepts exactly 10,000 posts in a set and rejects 10,001" do
      ids = (1..10_000).to_a
      expect(parse_backup(sets: { 1 => backup_set(post_ids: ids) }).sets.first.post_ids.size).to eq(10_000)

      expect(errors_for_backup(sets: { 1 => backup_set(post_ids: ids + [10_001]) }))
        .to eq(["sets.1.post_ids: 10001 posts, the maximum is 10000"])
    end

    it "rejects more post references in total than allowed" do
      allow(described_class).to receive(:max_total_post_refs).and_return(3)
      expect { parse_backup(favorites: { 1 => time, 2 => time }, sets: { 1 => backup_set(post_ids: [3]) }) }.not_to raise_error
      expect(errors_for_backup(favorites: { 1 => time, 2 => time }, sets: { 1 => backup_set(post_ids: [3, 4]) }))
        .to eq(["The backup references 4 posts in total, the maximum is 3"])
    end

    { name: 100, short_name: 50, description: 10_000 }.each do |field, max|
      it "accepts a set #{field} of exactly #{max} characters and rejects #{max + 1}" do
        expect { parse_backup(sets: { 1 => backup_set(field => "a" * max) }) }.not_to raise_error
        expect(errors_for_backup(sets: { 1 => backup_set(field => "a" * (max + 1)) }))
          .to eq(["sets.1.#{field} is #{max + 1} characters, the maximum is #{max}"])
      end
    end

    %w[about artinfo].each do |field|
      it "accepts profile #{field} of exactly 50,000 characters and rejects 50,001" do
        expect { parse_backup(field.to_sym => "x" * 50_000) }.not_to raise_error
        expect(errors_for_backup(field.to_sym => "x" * 50_001)).to eq(["profile.#{field} is 50001 characters, the maximum is 50000"])
      end
    end

    it "rejects set names shorter than 3 characters" do
      expect(errors_for_backup(sets: { 1 => backup_set(name: "ab") })).to eq(["sets.1.name is 2 characters, the minimum is 3"])
    end
  end

  describe "malformed input" do
    it "rejects invalid JSON" do
      expect(errors_for("{not json")).to include(include("isn't valid JSON"))
    end

    it "rejects invalid UTF-8" do
      expect(errors_for("{\"a\": \"\xff\"}".b)).to eq(["The file isn't valid UTF-8 text"])
    end

    it "rejects nesting deeper than a backup can be" do
      hash = backup_hash(sets: { 1 => backup_set(post_ids: [[1]]) })
      expect(errors_for_hash(hash)).to eq(["The file is nested more deeply than a backup can be"])
    end

    it "rejects duplicate keys" do
      raw = backup_json.sub('"favorites":{}', '"favorites":{"1":"2026-03-01T10:00:00Z","1":"2026-03-02T10:00:00Z"}')
      expect(errors_for(raw)).to include(match(/isn't valid JSON.*duplicate key/))
    end

    it "rejects a non-object root, missing keys and unknown keys" do
      expect(errors_for("[]")).to eq(["The file must contain a JSON object"])
      expect(errors_for_hash(backup_hash.except("sets"))).to eq(["the file is missing sets"])
      expect(errors_for_hash(backup_hash.merge("extra" => 1))).to eq(["the file has unexpected keys: extra"])
      expect(errors_for_backup(sets: { 1 => backup_set(owner: "x") })).to eq(["sets.1 has unexpected keys: owner"])
    end

    it "rejects unsupported format versions" do
      expect(errors_for_hash(backup_hash.merge("format_version" => 2))).to eq(["format_version 2 isn't supported (expected 1)"])
      expect(errors_for_hash(backup_hash.merge("format_version" => "1"))).to eq(["format_version \"1\" isn't supported (expected 1)"])
    end

    [0, -1, 1.5, "12", true, nil, 2_147_483_648].each do |bad|
      it "rejects #{bad.inspect} as a set post ID without coercing it" do
        expect(errors_for_backup(sets: { 1 => backup_set(post_ids: [1, bad]) }))
          .to eq(["sets.1.post_ids[1]: #{bad.inspect} isn't a valid post ID"])
      end
    end

    %w[0 -1 1.5 abc 01 2147483648].each do |bad|
      it "rejects #{bad.inspect} as a favorite post ID" do
        expect(errors_for_backup(favorites: { bad => time })).to eq(["favorites: #{bad.inspect} isn't a valid post ID"])
      end
    end

    it "rejects an invalid avatar post ID" do
      expect(errors_for_backup(avatar: { "post_id" => "5", "cropped" => false }))
        .to eq(["profile.avatar.post_id: \"5\" isn't a valid post ID"])
    end

    ["2026-03-01", "2026-03-01T10:00:00", "yesterday", "2026-13-01T10:00:00Z", 1_700_000_000].each do |bad|
      it "rejects the timestamp #{bad.inspect}" do
        expect(errors_for_backup(favorites: { 1 => bad }).first).to match(/favorites\.1: .*(isn't an ISO 8601 timestamp|isn't a valid timestamp)/)
      end
    end

    it "rejects timestamps outside the allowed range" do
      expect(errors_for_backup(favorites: { 1 => "1999-12-31T23:59:59Z" })).to eq(["favorites.1: 1999-12-31T23:59:59Z is outside the allowed range"])
      expect(errors_for_backup(favorites: { 1 => "2026-11-10T03:00:00Z" })).to eq(["favorites.1: 2026-11-10T03:00:00Z is outside the allowed range"])
    end

    it "rejects wrong types" do
      expect(errors_for_backup(sets: { 1 => backup_set(is_public: "yes") })).to eq(["sets.1.is_public must be true or false"])
      expect(errors_for_backup(sets: { 1 => backup_set(post_ids: "1,2") })).to eq(["sets.1.post_ids must be an array"])
      expect(errors_for_hash(backup_hash.merge("favorites" => [1, 2]))).to eq(["favorites must be an object"])
      expect(errors_for_backup(about: 5)).to eq(["profile.about must be a string"])
    end

    it "rejects invalid short names, null characters and duplicate posts in a set" do
      expect(errors_for_backup(sets: { 1 => backup_set(short_name: "has space") })).to eq(["sets.1.short_name \"has space\" isn't a valid set short name"])
      expect(errors_for_backup(sets: { 1 => backup_set(short_name: "123") })).to eq(["sets.1.short_name \"123\" isn't a valid set short name"])
      expect(errors_for_backup(sets: { 1 => backup_set(description: "a\u0000b") })).to eq(["sets.1.description contains a null character"])
      expect(errors_for_backup(sets: { 1 => backup_set(post_ids: [1, 2, 1]) })).to eq(["sets.1.post_ids lists the same post more than once"])
    end

    it "rejects a stored copy whose favorite order was tampered with" do
      stored = parse_backup(favorites: { 1 => time, 2 => time }).to_storage
      expect { described_class.from_storage(stored.merge("favorite_order" => %w[1])) }.to raise_error(described_class::Invalid)
      expect { described_class.from_storage(stored.merge("favorite_order" => %w[1 1])) }.to raise_error(described_class::Invalid)
      expect { described_class.from_storage(stored.merge("favorite_order" => %w[1 3])) }.to raise_error(described_class::Invalid)
      expect { described_class.from_storage(stored.except("favorite_order")) }.to raise_error(described_class::Invalid)
    end
  end
end
