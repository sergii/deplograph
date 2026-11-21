class FindingResolution < ApplicationRecord
  belongs_to :drift_finding
  belongs_to :runtime_attestation
  belongs_to :finding_verification_check
  belongs_to :remediation_attempt

  validates :resolved_at, presence: true
  validate :same_finding_and_runtime

  private

  def same_finding_and_runtime
    return unless drift_finding && runtime_attestation &&
                  finding_verification_check && remediation_attempt

    unless finding_verification_check.drift_finding_id == drift_finding_id &&
           remediation_attempt.drift_finding_id == drift_finding_id &&
           runtime_attestation.runtime_attestor.environment_id == drift_finding.target_environment_id &&
           runtime_attestation.runtime_attestor.organization_id == drift_finding.organization_id
      errors.add(:drift_finding, "resolution evidence must match the finding")
    end
  end
end
