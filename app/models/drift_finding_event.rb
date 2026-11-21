class DriftFindingEvent < ApplicationRecord
  ACTIONS = %w[detected observed status_changed note_added assigned].freeze

  belongs_to :drift_finding
  belongs_to :drift_comparison, optional: true
  belongs_to :actor, class_name: "User", optional: true

  validates :action, inclusion: { in: ACTIONS }
  validates :note, length: { maximum: 2_000 }, allow_nil: true
  validates :from_status, inclusion: { in: DriftFinding::STATUSES }, allow_nil: true
  validates :to_status, inclusion: { in: DriftFinding::STATUSES }, allow_nil: true
  validate :tenant_consistency

  private

  def tenant_consistency
    return unless drift_finding

    if drift_comparison && drift_comparison.organization_id != drift_finding.organization_id
      errors.add(:drift_comparison, "must belong to the same tenant")
    end
    if actor && !Membership.exists?(organization_id: drift_finding.organization_id, user_id: actor.id)
      errors.add(:actor, "must belong to the same tenant")
    end
  end
end
