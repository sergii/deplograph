class ConfigurationFingerprint < ApplicationRecord
  belongs_to :configuration_fingerprint_batch
  belongs_to :configuration_entry

  validates :digest, format: { with: /\A[a-f0-9]{64}\z/ }
  validates :configuration_entry_id,
    uniqueness: { scope: :configuration_fingerprint_batch_id }
  validate :entry_belongs_to_snapshot

  private

  def entry_belongs_to_snapshot
    return unless configuration_fingerprint_batch && configuration_entry

    if configuration_entry.configuration_snapshot_id != configuration_fingerprint_batch.configuration_snapshot_id
      errors.add(:configuration_entry, "must belong to the fingerprint batch's snapshot")
    end
  end
end
