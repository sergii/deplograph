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
  validates :workload, format: { with: /\A[a-z0-9](?:[-a-z0-9.]*[a-z0-9])?\z/ },
    length: { maximum: 120 }
  validates :image_repository, format: {
    with: %r{\A[a-zA-Z0-9._-]+(?::[0-9]+)?(?:/[a-zA-Z0-9._-]+)+\z}
  }
  validates :expected_replicas, numericality: {
    only_integer: true, greater_than: 0, less_than_or_equal_to: 1_000
  }
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
  rescue OpenSSL::PKey::PKeyError, OpenSSL::PKey::PKeyError => error
    errors.add(:public_key_pem, "is not a valid Ed25519 public key")
  end
end
