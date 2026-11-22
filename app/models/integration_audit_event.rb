class IntegrationAuditEvent < ApplicationRecord
  belongs_to :organization
  belongs_to :integration_credential

  validates :action, inclusion: { in: %w[issued revoked] }
  validate :credential_belongs_to_organization

  private

  def credential_belongs_to_organization
    return unless organization && integration_credential

    if integration_credential.organization_id != organization.id
      errors.add(:integration_credential, "must belong to organization")
    end
  end
end
