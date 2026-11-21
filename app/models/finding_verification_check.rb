class FindingVerificationCheck < ApplicationRecord
  TRIGGERS = %w[manual new_comparison].freeze
  OUTCOMES = %w[still_affected candidate_clear inconclusive policy_changed].freeze
  REASONS = %w[
    issue_still_present newer_remediation_required missing_target_evidence
    comparison_precedes_remediation incomplete_evidence old_or_stale_evidence
    policy_exception_changed fresh_comparison_no_issue no_comparable_evidence
  ].freeze

  belongs_to :drift_finding
  belongs_to :drift_comparison
  belongs_to :remediation_attempt, optional: true
  belongs_to :requested_by, class_name: "User", optional: true

  validates :trigger, inclusion: { in: TRIGGERS }
  validates :outcome, inclusion: { in: OUTCOMES }
  validates :reason_code, inclusion: { in: REASONS }
  validates :evidence_quality, inclusion: { in: DriftFinding::EVIDENCE_QUALITIES }
  validates :checked_at, presence: true
  validates :drift_comparison_id, uniqueness: { scope: :drift_finding_id }
  validate :evidence_matches_finding

  private

  def evidence_matches_finding
    return unless drift_finding && drift_comparison

    unless drift_comparison.organization_id == drift_finding.organization_id &&
           drift_comparison.application_id == drift_finding.application_id &&
           drift_comparison.baseline_environment_id == drift_finding.baseline_environment_id &&
           drift_comparison.target_environment_id == drift_finding.target_environment_id &&
           drift_comparison.mode == drift_finding.latest_comparison.mode
      errors.add(:drift_comparison, "must match the finding tenant, environments and evidence mode")
    end
    if remediation_attempt && remediation_attempt.drift_finding_id != drift_finding.id
      errors.add(:remediation_attempt, "must belong to the same finding")
    end
    if requested_by && !Membership.exists?(organization_id: drift_finding.organization_id, user_id: requested_by.id)
      errors.add(:requested_by, "must belong to the finding organization")
    end
    if authoritative
      errors.add(:authoritative, "cannot be true without an independently attested verifier")
    end
  end
end
