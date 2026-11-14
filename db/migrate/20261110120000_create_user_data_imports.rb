# frozen_string_literal: true

# Tracks a user's restore of an exported data backup (favorites, sets, profile).
# The row holds the validated backup between upload and the background run, the
# worker's lease, and the source -> destination set mapping that keeps a resumed
# run from creating duplicate sets. Each user gets one import.
class CreateUserDataImports < ActiveRecord::Migration[8.1]
  def change
    create_table :user_data_imports do |t|
      t.references :user, null: false, foreign_key: true, type: :integer, index: false
      t.text :status, null: false, default: "pending"
      t.text :step
      t.text :error_message

      t.boolean :import_favorites, null: false, default: false
      t.boolean :import_sets, null: false, default: false
      t.boolean :import_profile, null: false, default: false
      t.boolean :replace_profile, null: false, default: false

      t.text :file_name
      t.integer :file_size

      t.jsonb :document
      t.jsonb :preview, null: false, default: {}
      t.jsonb :results, null: false, default: {}
      t.jsonb :set_map, null: false, default: {}

      t.uuid :run_token
      t.datetime :lease_expires_at
      t.boolean :needs_reindex, null: false, default: false
      t.bigint :reindex_generation, null: false, default: 0

      t.datetime :queued_at
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps

      # One import per user. An unconfirmed upload is replaced by deleting it first.
      t.index :user_id, unique: true
      t.index :run_token, unique: true
    end
  end
end
