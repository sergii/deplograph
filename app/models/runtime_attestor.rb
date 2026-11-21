require "openssl"

class RuntimeAttestor < ApplicationRecord
  belongs_to :organization
  belongs_to :application
  belongs_to :environment
  belongs_to :integration_credential
  belongs_to :approved_by, class_name: "User"
  has_many :runtime_attestation_challenges, dependent: :destroy
  has_many :runtime_attestations, dependent: :destroy

  validates :name, presence: true, length: { maximum: 120 }
  validates :image_repository, format: {
    with: %r{\A[a-zA-Z0-9._-]+(?::[0-9]+)?(?:/[a-zA-Z0-9._-]+)+\z}
  }
  validate :expected_workload_contract
  validates :public_key_pem, presence: true
  validate :signed_source_is_authorized
  validate :public_key_is_ed25519

  def active?
    revoked_at.nil? && integration_credential.active?
  end

  def signing_key
    OpenSSL::PKey.read(public_key_pem)
  end

  private

  def expected_workload_contract
    unless expected_workloads.is_a?(Hash) && expected_workloads.size.between?(1, 20) &&
           expected_workloads.keys.all? { |name|
             name.is_a?(String) && name.match?(/\A[a-z0-9](?:[-a-z0-9.]*[a-z0-9])?\z/) && name.length <= 120
           } &&
           expected_workloads.values.all? { |count| count.is_a?(Integer) && count.between?(1, 1_000) } &&
           expected_workloads.values.sum <= 1_000
      errors.add(:expected_workloads, "must describe 1-20 named workloads with a total of 1-1000 expected replicas")
    end
  end

  def signed_source_is_authorized
    return unless organization && application && environment &&
                  integration_credential && approved_by

    unless application.organization_id == organization.id &&
           environment.application_id == application.id &&
           integration_credential.organization_id == organization.id &&
           Membership.exists?(organization_id: organization.id,
             user_id: approved_by_id, role: %w[owner admin]) &&
           integration_credential.permits?(permission: "observe",
             provider: "kubernetes", repository: application.repository_full_name,
             environment: environment.name)
      errors.add(:integration_credential, "must be a scoped Kubernetes observer approved by an owner/admin")
    end
  end

  def public_key_is_ed25519
    return if public_key_pem.blank?

    key = signing_key
    errors.add(:public_key_pem, "must be an Ed25519 public key") unless
      key.oid == "ED25519" && key.public_to_pem == public_key_pem
  rescue OpenSSL::PKey::PKeyError, OpenSSL::PKey::PKeyError
    errors.add(:public_key_pem, "is not a valid Ed25519 public key")
  end
end
