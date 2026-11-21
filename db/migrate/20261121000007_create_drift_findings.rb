class CreateDriftFindings < ActiveRecord::Migration[8.1]
  def change
    create_table :drift_findings do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :application, null: false, foreign_key: true
      t.references :baseline_environment, null: false, foreign_key: { to_table: :environments }
      t.references :target_environment, null: false, foreign_key: { to_table: :environments }
      t.references :latest_comparison, null: false, foreign_key: { to_table: :drift_comparisons }
      t.references :assigned_to, foreign_key: { to_table: :users }
      t.string :fingerprint, null: false
      t.string :category, null: false
      t.string :subject, null: false
      t.string :title, null: false
      t.string :status, null: false, default: "open"
      t.string :severity, null: false, default: "unknown"
      t.string :priority, null: false, default: "p2"
      t.string :evidence_quality, null: false, default: "partial"
      t.text :next_action
      t.datetime :first_seen_at, null: false
      t.datetime :last_seen_at, null: false
      t.datetime :resolved_at
      t.timestamps
    end
    add_index :drift_findings, %i[organization_id fingerprint], unique: true,
      name: "idx_drift_findings_org_fingerprint"
    add_index :drift_findings, %i[organization_id status priority last_seen_at],
      name: "idx_drift_findings_filter"

    create_table :drift_finding_events do |t|
      t.references :drift_finding, null: false, foreign_key: true
      t.references :drift_comparison, foreign_key: true
      t.references :actor, foreign_key: { to_table: :users }
      t.string :action, null: false
      t.string :from_status
      t.string :to_status
      t.text :note
      t.timestamps
    end
    add_index :drift_finding_events, %i[drift_finding_id created_at],
      name: "idx_drift_finding_events_history"
  end
end
