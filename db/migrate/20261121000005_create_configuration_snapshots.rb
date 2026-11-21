class CreateConfigurationSnapshots < ActiveRecord::Migration[8.1]
  def change
    create_table :configuration_snapshots do |t|
      t.references :environment, null: false, foreign_key: true
      t.string :source, null: false
      t.string :scope, null: false
      t.string :workload, null: false
      t.string :collection_id, null: false
      t.string :completeness, null: false
      t.string :keys_sha256, null: false
      t.datetime :collected_at, null: false
      t.timestamps
    end
    add_index :configuration_snapshots, %i[environment_id source collection_id],
      unique: true, name: "idx_config_snapshots_delivery"
    add_index :configuration_snapshots,
      %i[environment_id workload scope collected_at],
      name: "idx_config_snapshots_latest"

    create_table :configuration_entries do |t|
      t.references :configuration_snapshot, null: false, foreign_key: true
      t.string :name, null: false
      t.timestamps
    end
    add_index :configuration_entries, %i[configuration_snapshot_id name],
      unique: true, name: "idx_config_entries_name"
  end
end
