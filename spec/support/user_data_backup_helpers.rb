# frozen_string_literal: true

# Builds backups in the version-1 format written by UserDataExport (e6ai/e6ai#50).
module UserDataBackupHelpers
  BACKUP_EXPORTED_AT = "2026-11-09T02:30:00Z"

  def backup_set(name: "Example Set", short_name: "example_set", post_ids: [], is_public: false, **overrides)
    {
      "name" => name, "short_name" => short_name, "description" => "", "created_at" => "2026-01-01T12:00:00Z",
      "updated_at" => "2026-02-01T12:00:00Z", "is_public" => is_public, "transfer_on_delete" => false, "post_ids" => post_ids,
    }.merge(overrides.transform_keys(&:to_s))
  end

  def backup_hash(favorites: {}, sets: {}, about: "", artinfo: "", avatar: nil)
    {
      "format_version" => 1,
      "exported_at" => BACKUP_EXPORTED_AT,
      "profile" => { "about" => about, "artinfo" => artinfo, "avatar" => avatar },
      "favorites" => favorites.transform_keys(&:to_s),
      "sets" => sets.transform_keys(&:to_s),
    }
  end

  def backup_json(...)
    backup_hash(...).to_json
  end

  def parse_backup(...)
    UserDataImport::Document.parse(backup_json(...))
  end
end

RSpec.configure do |config|
  config.include UserDataBackupHelpers
end
