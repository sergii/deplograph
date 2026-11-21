class ConfigurationPolicy < ApplicationRecord
  RULES = %w[must_match must_differ allowed_to_differ ignore].freeze

  belongs_to :application
  belongs_to :baseline_environment, class_name: "Environment"
  belongs_to :target_environment, class_name: "Environment"
  has_many :configuration_policy_changes, dependent: :destroy

  validates :name, presence: true,
    format: { with: Configuration::SnapshotRecorder::KEY_PATTERN }
  validates :workload, presence: true,
    format: { with: Configuration::SnapshotRecorder::WORKLOAD_PATTERN }
  validates :scope, inclusion: { in: ConfigurationSnapshot::SCOPES }
  validates :rule, inclusion: { in: RULES }
  validates :name, uniqueness: { scope: %i[application_id baseline_environment_id target_environment_id workload scope] }
  validate :matching_application_and_distinct_environments

  private

  def matching_application_and_distinct_environments
    return unless application && baseline_environment && target_environment

    unless baseline_environment.application_id == application.id &&
           target_environment.application_id == application.id
      errors.add(:application, "must own both environments")
    end
    if baseline_environment_id == target_environment_id
      errors.add(:target_environment, "must differ from baseline")
    end
  end
end
