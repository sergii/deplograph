class ReleaseArtifact < ApplicationRecord
  belongs_to :release
  belongs_to :artifact
  validate :artifact_belongs_to_release_application

  private

  def artifact_belongs_to_release_application
    return unless release && artifact
    errors.add(:artifact, "must belong to application") if release.application_id != artifact.application_id
  end
end
