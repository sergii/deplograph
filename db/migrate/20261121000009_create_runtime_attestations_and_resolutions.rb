class CreateRuntimeAttestationsAndResolutions < ActiveRecord::Migration[8.1]
  def change
    create_table :runtime_attestors do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :application, null: false, foreign_key: true
      t.references :environment, null: false, foreign_key: true
      t.references :integration_credential, null: false, foreign_key: true
      t.references :approved_by, null: false, foreign_key: { to_table: :users }
      t.string :name, null: false
      t.string :image_repository, null: false
      t.jsonb :expected_workloads, null: false, default: {}
      t.text :public_key_pem, null: false
      t.boolean :resolution_enabled, null: false, default: false
      t.datetime :revoked_at
      t.timestamps
    end
    add_index :runtime_attestors, %i[environment_id name],
      unique: true, name: "idx_runtime_attestors_identity"

    create_table :runtime_attestation_challenges do |t|
      t.references :runtime_attestor, null: false, foreign_key: true
      t.string :nonce, null: false
      t.datetime :expires_at, null: false
      t.datetime :consumed_at
      t.timestamps
    end
    add_index :runtime_attestation_challenges, :nonce, unique: true

    create_table :runtime_attestations do |t|
      t.references :runtime_attestor, null: false, foreign_key: true
      t.references :runtime_attestation_challenge, null: false, foreign_key: true,
        index: { unique: true, name: "idx_runtime_attestations_challenge" }
      t.string :observation_id, null: false
      t.string :image_digest, null: false
      t.integer :ready_replicas, null: false
      t.boolean :complete, null: false, default: false
      t.datetime :observed_at, null: false
      t.datetime :verified_at, null: false
      t.jsonb :signed_payload, null: false, default: {}
      t.text :signature, null: false
      t.timestamps
    end
    add_index :runtime_attestations, %i[runtime_attestor_id observation_id],
      unique: true, name: "idx_runtime_attestations_observation"
    add_index :runtime_attestations, %i[runtime_attestor_id observed_at],
      name: "idx_runtime_attestations_latest"

    create_table :finding_resolutions do |t|
      t.references :drift_finding, null: false, foreign_key: true
      t.references :runtime_attestation, null: false, foreign_key: true
      t.references :finding_verification_check, null: false, foreign_key: true
      t.references :remediation_attempt, null: false, foreign_key: true
      t.datetime :resolved_at, null: false
      t.timestamps
    end
    add_index :finding_resolutions, %i[drift_finding_id resolved_at],
      name: "idx_finding_resolutions_history"
  end
end
