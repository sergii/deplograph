class CreateIdentityAndIntegrationCredentials < ActiveRecord::Migration[8.1]
  def up
    create_table :organizations do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.timestamps
    end
    add_index :organizations, :slug, unique: true

    create_table :users do |t|
      t.string :email, null: false
      t.string :password_digest, null: false
      t.timestamps
    end
    add_index :users, "LOWER(email)", unique: true, name: "idx_users_lower_email"

    create_table :memberships do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :role, null: false, default: "viewer"
      t.timestamps
    end
    add_index :memberships, %i[organization_id user_id], unique: true

    # Do not silently grant new users access to pre-existing records.
    add_reference :applications, :organization, foreign_key: true
    if select_value("SELECT COUNT(*) FROM applications").to_i.positive?
      execute <<~SQL
        INSERT INTO organizations (name, slug, created_at, updated_at)
        VALUES ('Legacy data - unclaimed', 'legacy-unclaimed', NOW(), NOW())
      SQL
      execute <<~SQL
        UPDATE applications
        SET organization_id = (SELECT id FROM organizations WHERE slug = 'legacy-unclaimed')
        WHERE organization_id IS NULL
      SQL
    end
    change_column_null :applications, :organization_id, false
    remove_index :applications, :repository_full_name
    add_index :applications, %i[organization_id repository_full_name], unique: true,
      name: "idx_applications_org_repository"

    add_reference :github_installations, :organization, foreign_key: true

    create_table :integration_credentials do |t|
      t.references :organization, null: false, foreign_key: true
      t.string :name, null: false
      t.string :provider, null: false
      t.string :token_prefix, null: false
      t.string :token_digest, null: false
      t.jsonb :permissions, null: false, default: []
      t.jsonb :repository_scopes, null: false, default: []
      t.jsonb :environment_scopes, null: false, default: []
      t.datetime :expires_at
      t.datetime :revoked_at
      t.datetime :last_used_at
      t.timestamps
    end
    add_index :integration_credentials, :token_prefix, unique: true
    add_index :integration_credentials, :token_digest, unique: true
    add_index :integration_credentials, %i[organization_id provider]

    create_table :integration_audit_events do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :integration_credential, null: false, foreign_key: true
      t.string :action, null: false
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
  end

  def down
    drop_table :integration_audit_events
    drop_table :integration_credentials
    remove_reference :github_installations, :organization
    remove_index :applications, name: "idx_applications_org_repository"
    remove_reference :applications, :organization
    add_index :applications, :repository_full_name, unique: true
    drop_table :memberships
    drop_table :users
    drop_table :organizations
  end
end
