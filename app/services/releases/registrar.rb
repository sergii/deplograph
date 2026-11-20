module Releases
  class Registrar
    class Conflict < StandardError; end

    def call(body)
      repository = body.fetch("repository")
      raise ArgumentError, "Invalid repository" unless repository.match?(/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/)

      sha = body.fetch("commit_sha")
      raise ArgumentError, "Invalid commit SHA" unless sha.match?(/\A[a-f0-9]{40}\z/)

      name = body.fetch("release")
      raise ArgumentError, "Invalid release name" unless name.is_a?(String) && name.match?(/\A[\w.-]{1,128}\z/)

      entries = body.fetch("artifacts")
      raise ArgumentError, "At least one artifact required" unless entries.is_a?(Array) && entries.any? && entries.length <= 100

      ApplicationRecord.transaction do
        app = Application.find_or_create_by!(repository_full_name: repository) do |record|
          record.name = repository.split("/").last
        end
        revision = app.source_revisions.find_or_create_by!(commit_sha: sha)
        release = app.releases.find_or_initialize_by(name: name)
        if release.persisted? && release.source_revision_id != revision.id
          raise Conflict, "Release already refers to another commit"
        end

        release.source_revision = revision
        release.published_at ||= Time.current
        release.save!

        if body["build"].is_a?(Hash)
          data = body["build"]
          build = revision.builds.find_or_create_by!(
            provider: data.fetch("provider"), external_id: data.fetch("id")
          )
        end

        entries.each do |entry|
          raise ArgumentError, "Artifact must be an object" unless entry.is_a?(Hash)

          digest = entry.fetch("image_digest")
          raise ArgumentError, "Invalid image digest" unless digest.match?(/\Asha256:[a-f0-9]{64}\z/)
          identifier = entry.fetch("identifier")
          raise ArgumentError, "Artifact identity must contain digest" unless identifier.include?(digest)

          artifact = app.artifacts.find_or_initialize_by(identifier: identifier)
          if artifact.persisted? && artifact.image_digest.present? && artifact.image_digest != digest
            raise Conflict, "Artifact identifier already refers to another digest"
          end
          artifact.assign_attributes(kind: "image", image_digest: digest, commit_sha: sha)
          artifact.save!
          release.release_artifacts.find_or_create_by!(artifact: artifact)
          build&.build_artifacts&.find_or_create_by!(artifact: artifact)
        end
        release
      end
    end
  end
end
