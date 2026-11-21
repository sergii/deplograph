class Release < ApplicationRecord
  has_many :remediation_attempts, dependent: :nullify
  belongs_to :application
  belongs_to :source_revision, optional: true
  has_many :release_artifacts, dependent: :destroy
  has_many :artifacts, through: :release_artifacts
  has_many :deployments, dependent: :nullify

  validates :name, presence: true, uniqueness: { scope: :application_id }
  validate :source_revision_belongs_to_application

  private

  def source_revision_belongs_to_application
    return unless source_revision && application
    errors.add(:source_revision, "must belong to application") if source_revision.application_id != application.id
  end
end
