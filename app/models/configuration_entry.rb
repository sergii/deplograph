class ConfigurationEntry < ApplicationRecord
  belongs_to :configuration_snapshot

  validates :name, presence: true,
    format: { with: /\A[A-Za-z_][A-Za-z0-9_]{0,127}\z/ }
  validates :name, uniqueness: { scope: :configuration_snapshot_id }
end
