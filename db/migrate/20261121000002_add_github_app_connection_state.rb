class AddGithubAppConnectionState < ActiveRecord::Migration[8.1]
  def change
    add_reference :github_installations, :linked_by, foreign_key: { to_table: :users }
    add_column :github_installations, :linked_at, :datetime
    add_column :github_installations, :last_synced_at, :datetime
    add_column :github_installations, :last_sync_error, :text

    add_column :github_repository_grants, :sbom_report_uuid, :string
    add_column :github_repository_grants, :sbom_sync_status, :string, null: false, default: "not_requested"
    add_column :github_repository_grants, :last_imported_at, :datetime
    add_column :github_repository_grants, :last_import_error, :text
    add_index :github_repository_grants, :sbom_sync_status

    create_table :github_webhook_deliveries do |t|
      t.string :delivery_id, null: false
      t.string :event, null: false
      t.string :payload_sha256, null: false
      t.datetime :received_at, null: false
      t.timestamps
    end
    add_index :github_webhook_deliveries, :delivery_id, unique: true
  end
end
