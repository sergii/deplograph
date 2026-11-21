class RuntimeAttestationChallenge < ApplicationRecord
  belongs_to :runtime_attestor
  has_one :runtime_attestation, dependent: :destroy

  validates :nonce, presence: true, uniqueness: true,
    format: { with: /\A[a-f0-9]{64}\z/ }
  validates :expires_at, presence: true

  def available?
    consumed_at.nil? && expires_at.future? && runtime_attestor.active?
  end
end
