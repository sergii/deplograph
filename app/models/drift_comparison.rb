class DriftComparison < ApplicationRecord
  belongs_to :organization
  belongs_to :application
  belongs_to :baseline_environment, class_name: "Environment"
  belongs_to :target_environment, class_name: "Environment"

  validates :mode, inclusion: { in: %w[reported observed] }
  validates :status, inclusion: { in: %w[same different partial unknown stale] }
  validates :compared_at, presence: true
  validate :all_resources_belong_to_organization

  private

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
