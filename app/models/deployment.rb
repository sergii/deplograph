class Deployment < ApplicationRecord
  belongs_to :environment
  belongs_to :artifact
  belongs_to :release, optional: true
  has_many :remediation_attempts, dependent: :nullify
  has_many :deployment_events, dependent: :nullify
  has_many :deployment_observations, dependent: :nullify

  validates :deployed_at, presence: true
  validates :status, inclusion: { in: %w[reported observed] }
  validate :artifact_belongs_to_environment_application

  private

  def artifact_belongs_to_environment_application
    return if artifact.nil? || environment.nil?
    return if artifact.application_id == environment.application_id

    errors.add(:artifact, "must belong to the environment's application")
  end
end
