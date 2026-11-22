class CreateInventoryScanHistory < ActiveRecord::Migration[8.1]
  def change
    add_column :inventory_snapshots, :coverage_status, :string, null: false, default: "partial"
    add_column :inventory_snapshots, :manifest_type, :string

    create_table :vulnerability_scan_runs do |t|
      t.references :inventory_snapshot, null: false, foreign_key: true
      t.string :provider, null: false, default: "osv"
      t.string :trigger, null: false, default: "manual"
      t.string :status, null: false, default: "running"
      t.integer :match_count
      t.datetime :started_at, null: false
      t.datetime :completed_at
      t.string :error_class
      t.timestamps
    end
    add_index :vulnerability_scan_runs, %i[inventory_snapshot_id started_at],
      name: "idx_scan_runs_snapshot_started"
  end
end
