class RuntimeAttestation < ApplicationRecord
  belongs_to :runtime_attestor
  belongs_to :runtime_attestation_challenge
  has_many :finding_resolutions, dependent: :destroy

  validates :observation_id, presence: true,
    uniqueness: { scope: :runtime_attestor_id }
  validates :image_digest, format: { with: /\Asha256:[a-f0-9]{64}\z/ }
  validates :ready_replicas, numericality: {
    only_integer: true, greater_than_or_equal_to: 0
  }
  validates :observed_at, :verified_at, presence: true
  validates :signature, presence: true
  validate :bound_to_signed_source

  private

  def bound_to_signed_source
    return unless runtime_attestor && runtime_attestation_challenge

    if runtime_attestation_challenge.runtime_attestor_id != runtime_attestor_id
      errors.add(:runtime_attestation_challenge, "must belong to attestor")
    end
  end
end
