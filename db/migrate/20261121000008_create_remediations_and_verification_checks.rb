class CreateRemediationsAndVerificationChecks < ActiveRecord::Migration[8.1]
  def change
    create_table :remediation_attempts do |t|
      t.references :drift_finding, null: false, foreign_key: true
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.references :release, foreign_key: true
      t.references :deployment, foreign_key: true
      t.references :vulnerability_scan_run, foreign_key: true
      t.string :status, null: false, default: "planned"
      t.text :description, null: false
      t.string :reference_url
      t.timestamps
    end
    add_index :remediation_attempts, %i[drift_finding_id created_at],
      name: "idx_remediation_attempts_timeline"

    create_table :finding_verification_checks do |t|
      t.references :drift_finding, null: false, foreign_key: true
      t.references :drift_comparison, null: false, foreign_key: true
      t.references :remediation_attempt, foreign_key: true
      t.references :requested_by, foreign_key: { to_table: :users }
      t.string :trigger, null: false
      t.string :outcome, null: false
      t.string :reason_code, null: false
      t.string :evidence_quality, null: false, default: "unknown"
      t.boolean :authoritative, null: false, default: false
      t.datetime :checked_at, null: false
      t.timestamps
    end
    add_index :finding_verification_checks, %i[drift_finding_id drift_comparison_id],
      unique: true, name: "idx_finding_verification_once_per_comparison"
    add_index :finding_verification_checks, %i[drift_finding_id checked_at],
      name: "idx_verification_checks_timeline"
  end
end
