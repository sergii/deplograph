class DriftFinding < ApplicationRecord
  STATUSES = %w[open acknowledged investigating verification_pending resolved dismissed].freeze
  SEVERITIES = %w[unknown low medium high critical].freeze
  PRIORITIES = %w[p1 p2 p3].freeze
  EVIDENCE_QUALITIES = %w[reported_only partial stale unknown verified].freeze

  belongs_to :organization
  belongs_to :application
  belongs_to :baseline_environment, class_name: "Environment"
  belongs_to :target_environment, class_name: "Environment"
  belongs_to :latest_comparison, class_name: "DriftComparison"
  belongs_to :assigned_to, class_name: "User", optional: true
  has_many :drift_finding_events, dependent: :destroy

  validates :fingerprint, format: { with: /\A[a-f0-9]{64}\z/ },
    uniqueness: { scope: :organization_id }
  validates :category, :subject, :title, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :severity, inclusion: { in: SEVERITIES }
  validates :priority, inclusion: { in: PRIORITIES }
  validates :evidence_quality, inclusion: { in: EVIDENCE_QUALITIES }
  validates :next_action, length: { maximum: 1_500 }, allow_nil: true
  validates :first_seen_at, :last_seen_at, presence: true
  validate :tenant_consistency

  scope :unresolved, -> { where.not(status: %w[resolved dismissed]) }

  private

  def tenant_consistency
    return unless organization && application && baseline_environment &&
                  target_environment && latest_comparison

    unless application.organization_id == organization.id &&
           baseline_environment.application_id == application.id &&
           target_environment.application_id == application.id &&
           latest_comparison.organization_id == organization.id &&
           latest_comparison.application_id == application.id &&
           latest_comparison.baseline_environment_id == baseline_environment.id &&
           latest_comparison.target_environment_id == target_environment.id
      errors.add(:application, "finding evidence must belong to the same tenant and environments")
    end
    if assigned_to && !Membership.exists?(organization_id: organization.id, user_id: assigned_to.id)
      errors.add(:assigned_to, "must be a member of this organization")
    end
  end
end
