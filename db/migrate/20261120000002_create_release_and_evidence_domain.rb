class CreateReleaseAndEvidenceDomain < ActiveRecord::Migration[8.1]
  def change
    create_table :source_revisions do |t|
      t.references :application, null: false, foreign_key: true
      t.string :commit_sha, null: false
      t.string :ref
      t.timestamps
    end
    add_index :source_revisions, %i[application_id commit_sha], unique: true

    create_table :builds do |t|
      t.references :source_revision, null: false, foreign_key: true
      t.string :provider, null: false
      t.string :external_id, null: false
      t.string :status, null: false, default: "completed"
      t.datetime :completed_at
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :builds, %i[source_revision_id provider external_id], unique: true,
      name: "idx_builds_unique"

    create_table :build_artifacts do |t|
      t.references :build, null: false, foreign_key: true
      t.references :artifact, null: false, foreign_key: true
      t.timestamps
    end
    add_index :build_artifacts, %i[build_id artifact_id], unique: true

    create_table :releases do |t|
      t.references :application, null: false, foreign_key: true
      t.references :source_revision, foreign_key: true
      t.string :name, null: false
      t.datetime :published_at
      t.timestamps
    end
    add_index :releases, %i[application_id name], unique: true

    create_table :release_artifacts do |t|
      t.references :release, null: false, foreign_key: true
      t.references :artifact, null: false, foreign_key: true
      t.timestamps
    end
    add_index :release_artifacts, %i[release_id artifact_id], unique: true

    add_reference :deployments, :release, foreign_key: true

    create_table :deployment_events do |t|
      t.references :environment, null: false, foreign_key: true
      t.references :deployment, foreign_key: true
      t.string :source, null: false
      t.string :event_id, null: false
      t.string :event_type, null: false
      t.datetime :occurred_at, null: false
      t.jsonb :payload, null: false, default: {}
      t.timestamps
    end
    add_index :deployment_events, %i[environment_id source event_id], unique: true,
      name: "idx_deployment_events_dedup"

    create_table :deployment_observations do |t|
      t.references :environment, null: false, foreign_key: true
      t.references :deployment, foreign_key: true
      t.references :artifact, foreign_key: true
      t.string :source, null: false
      t.string :event_id, null: false
      t.string :workload, null: false
      t.string :image_digest, null: false
      t.datetime :observed_at, null: false
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :deployment_observations, %i[environment_id source event_id], unique: true,
      name: "idx_observations_dedup"
    add_index :deployment_observations, %i[environment_id workload observed_at],
      name: "idx_observations_workload"

    create_table :github_installations do |t|
      t.bigint :installation_id, null: false
      t.bigint :account_id
      t.string :account_login, null: false
      t.string :state, null: false, default: "active"
      t.jsonb :permissions, null: false, default: {}
      t.datetime :last_event_at
      t.timestamps
    end
    add_index :github_installations, :installation_id, unique: true

    create_table :github_repository_grants do |t|
      t.references :github_installation, null: false, foreign_key: true
      t.bigint :github_repository_id, null: false
      t.string :full_name, null: false
      t.boolean :enabled, null: false, default: true
      t.timestamps
    end
    add_index :github_repository_grants, %i[github_installation_id github_repository_id],
      unique: true, name: "idx_github_grants_unique"
  end
end
