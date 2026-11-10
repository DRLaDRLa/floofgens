# frozen_string_literal: true

# Tracks a user's restore of an exported data backup (favorites, sets, profile).
# The row holds the validated backup between upload and the background run, the
# worker's lease, and the source -> destination set mapping that keeps repeated
# imports from creating duplicate sets.
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

      t.inet :creator_ip_addr
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

      t.index :user_id
      # At most one open import per user.
      t.index :user_id, unique: true, name: "index_user_data_imports_on_user_id_open",
                        where: "status IN ('pending', 'queued', 'running')"
    end
  end
end
