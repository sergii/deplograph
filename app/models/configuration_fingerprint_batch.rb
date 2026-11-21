class ConfigurationFingerprintBatch < ApplicationRecord
  ALGORITHM = "HMAC-SHA256-v1"

  belongs_to :configuration_snapshot
  has_many :configuration_fingerprints, dependent: :destroy

  validates :key_id, presence: true,
    format: { with: /\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}\z/ },
    uniqueness: { scope: :configuration_snapshot_id }
  validates :algorithm, inclusion: { in: [ALGORITHM] }
  validates :fingerprints_sha256, format: { with: /\A[a-f0-9]{64}\z/ }
  validates :collected_at, presence: true

  def fingerprints_by_name
    configuration_fingerprints.includes(:configuration_entry).each_with_object({}) do |fingerprint, entries|
      entries[fingerprint.configuration_entry.name] = fingerprint.digest
    end
  end
end
