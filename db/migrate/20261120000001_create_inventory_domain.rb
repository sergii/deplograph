class CreateInventoryDomain < ActiveRecord::Migration[8.1]
  def change
    create_table :applications do |t|
      t.string :name, null: false
      t.string :repository_full_name, null: false
      t.jsonb :repository_metadata, null: false, default: {}
      t.datetime :inspected_at
      t.timestamps
    end
    add_index :applications, :repository_full_name, unique: true

    create_table :environments do |t|
      t.references :application, null: false, foreign_key: true
      t.string :name, null: false
      t.string :kind, null: false, default: "other"
      t.string :state, null: false, default: "active"
      t.string :external_id
      t.datetime :expires_at
      t.datetime :last_reported_at
      t.datetime :last_observed_at
      t.timestamps
    end
    add_index :environments, %i[application_id name], unique: true

    create_table :artifacts do |t|
      t.references :application, null: false, foreign_key: true
      t.string :kind, null: false, default: "source"
      t.string :identifier, null: false
      t.string :image_digest
      t.string :commit_sha
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :artifacts, %i[application_id identifier], unique: true

    create_table :inventory_snapshots do |t|
      t.references :artifact, null: false, foreign_key: true
      t.string :format, null: false
      t.string :source, null: false, default: "api"
      t.string :sha256, null: false
      t.jsonb :raw_document, null: false, default: {}
      t.string :match_status, null: false, default: "not_scanned"
      t.datetime :match_completed_at
      t.text :match_error
      t.timestamps
    end
    add_index :inventory_snapshots, %i[artifact_id sha256], unique: true, name: "idx_snapshots_artifact_digest"

    create_table :components do |t|
      t.string :purl, null: false
      t.string :name, null: false
      t.string :version
      t.string :ecosystem
      t.timestamps
    end
    add_index :components, :purl, unique: true

    create_table :component_occurrences do |t|
      t.references :inventory_snapshot, null: false, foreign_key: true
      t.references :component, null: false, foreign_key: true
      t.string :bom_ref
      t.timestamps
    end
    add_index :component_occurrences, %i[inventory_snapshot_id component_id bom_ref],
      unique: true, name: "idx_occurrences_by_component_and_ref"

    create_table :dependency_edges do |t|
      t.references :inventory_snapshot, null: false, foreign_key: true
      t.references :from_occurrence, null: false, foreign_key: { to_table: :component_occurrences }
      t.references :to_occurrence, null: false, foreign_key: { to_table: :component_occurrences }
      t.timestamps
    end
    add_index :dependency_edges, %i[inventory_snapshot_id from_occurrence_id to_occurrence_id],
      unique: true, name: "idx_edges_unique"

    create_table :vulnerabilities do |t|
      t.string :identifier, null: false
      t.datetime :source_modified_at
      t.timestamps
    end
    add_index :vulnerabilities, :identifier, unique: true

    create_table :vulnerability_matches do |t|
      t.references :inventory_snapshot, null: false, foreign_key: true
      t.references :component_occurrence, null: false, foreign_key: true
      t.references :vulnerability, null: false, foreign_key: true
      t.string :source, null: false, default: "osv"
      t.timestamps
    end
    add_index :vulnerability_matches, %i[component_occurrence_id vulnerability_id source],
      unique: true, name: "idx_matches_unique"

    create_table :deployments do |t|
      t.references :environment, null: false, foreign_key: true
      t.references :artifact, null: false, foreign_key: true
      t.string :provider, null: false, default: "ci"
      t.string :status, null: false, default: "reported"
      t.string :external_id
      t.string :commit_sha
      t.datetime :deployed_at, null: false
      t.datetime :observed_at
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :deployments, %i[environment_id external_id], unique: true,
      where: "external_id IS NOT NULL"
  end
end
