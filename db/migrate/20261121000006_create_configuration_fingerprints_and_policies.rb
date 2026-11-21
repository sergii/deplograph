class CreateConfigurationFingerprintsAndPolicies < ActiveRecord::Migration[8.1]
  def change
    create_table :configuration_fingerprint_batches do |t|
      t.references :configuration_snapshot, null: false, foreign_key: true
      t.string :key_id, null: false
      t.string :algorithm, null: false
      t.string :fingerprints_sha256, null: false
      t.datetime :collected_at, null: false
      t.timestamps
    end
    add_index :configuration_fingerprint_batches, %i[configuration_snapshot_id key_id],
      unique: true, name: "idx_config_fingerprint_batches_snapshot_key"

    create_table :configuration_fingerprints do |t|
      t.references :configuration_fingerprint_batch, null: false, foreign_key: true,
        index: { name: "idx_config_fingerprints_batch" }
      t.references :configuration_entry, null: false, foreign_key: true
      t.string :digest, null: false
      t.timestamps
    end
    add_index :configuration_fingerprints,
      %i[configuration_fingerprint_batch_id configuration_entry_id],
      unique: true, name: "idx_config_fingerprints_batch_entry"

    create_table :configuration_policies do |t|
      t.references :application, null: false, foreign_key: true
      t.references :baseline_environment, null: false, foreign_key: { to_table: :environments }
      t.references :target_environment, null: false, foreign_key: { to_table: :environments }
      t.string :workload, null: false
      t.string :scope, null: false
      t.string :name, null: false
      t.string :rule, null: false
      t.timestamps
    end
    add_index :configuration_policies,
      %i[application_id baseline_environment_id target_environment_id workload scope name],
      unique: true, name: "idx_config_policies_unique"

    create_table :configuration_policy_changes do |t|
      t.references :configuration_policy, null: false, foreign_key: true
      t.references :integration_credential, null: false, foreign_key: true
      t.string :previous_rule
      t.string :new_rule, null: false
      t.timestamps
    end
  end
end
