class ConfigurationPolicyChange < ApplicationRecord
  belongs_to :configuration_policy
  belongs_to :integration_credential

  validates :new_rule, inclusion: { in: ConfigurationPolicy::RULES }
  validates :previous_rule, inclusion: { in: ConfigurationPolicy::RULES }, allow_nil: true
  validate :same_organization

  private

  def same_organization
    return unless configuration_policy && integration_credential

    if configuration_policy.application.organization_id != integration_credential.organization_id
      errors.add(:integration_credential, "must belong to policy organization")
    end
  end
end
