class DriftComparison < ApplicationRecord
  belongs_to :organization
  belongs_to :application
  belongs_to :baseline_environment, class_name: "Environment"
  belongs_to :target_environment, class_name: "Environment"

  validates :mode, inclusion: { in: %w[reported observed configuration_names configuration_fingerprints] }
  validates :status, inclusion: { in: %w[same different partial unknown stale] }
  validates :compared_at, presence: true
  has_many :drift_finding_events, dependent: :nullify
  has_many :finding_verification_checks, dependent: :destroy
  after_create :materialize_findings
  after_create :evaluate_remediations

  validate :all_resources_belong_to_organization

  private

  def materialize_findings
    Findings::IngestComparison.new.call(self)
  end

  def evaluate_remediations
    Findings::EvaluateNewComparison.new.call(self)
  end

  def all_resources_belong_to_organization
    return unless organization && application && baseline_environment && target_environment

    if application.organization_id != organization.id ||
       baseline_environment.application_id != application.id ||
       target_environment.application_id != application.id
      errors.add(:application, "and environments must belong to the same organization")
    end
    if baseline_environment.id == target_environment.id
      errors.add(:target_environment, "must differ from baseline")
    end
  end
end
