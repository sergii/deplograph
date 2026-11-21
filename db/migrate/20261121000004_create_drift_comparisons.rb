class CreateDriftComparisons < ActiveRecord::Migration[8.1]
  def change
    create_table :drift_comparisons do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :application, null: false, foreign_key: true
      t.references :baseline_environment, null: false,
        foreign_key: { to_table: :environments }
      t.references :target_environment, null: false,
        foreign_key: { to_table: :environments }
      t.string :mode, null: false
      t.string :status, null: false
      t.jsonb :result, null: false, default: {}
      t.datetime :compared_at, null: false
      t.timestamps
    end
    add_index :drift_comparisons, %i[organization_id application_id compared_at],
      name: "idx_drift_comparisons_history"
  end
end
