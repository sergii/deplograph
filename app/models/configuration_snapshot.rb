class ConfigurationSnapshot < ApplicationRecord
  belongs_to :environment
  has_many :configuration_entries, dependent: :destroy

  SCOPES = %w[declared process].freeze
  COMPLETENESS = %w[complete partial].freeze

  validates :source, :workload, :collection_id, :keys_sha256, :collected_at, presence: true
  validates :scope, inclusion: { in: SCOPES }
  validates :completeness, inclusion: { in: COMPLETENESS }
  validates :collection_id, uniqueness: { scope: %i[environment_id source] }
end
