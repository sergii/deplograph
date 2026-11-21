module Artifacts
  class IdentityConflict < StandardError; end

  class Registrar
    DIGEST = /\Asha256:[a-f0-9]{64}\z/
    COMMIT_SHA = /\A[a-f0-9]{40}\z/

    def call(application:, identifier:, kind:, image_digest: nil, commit_sha: nil)
      raise ArgumentError, "Artifact identifier is required" if identifier.blank?
      raise ArgumentError, "Unknown artifact kind" unless %w[source image binary].include?(kind)
      if image_digest.present? && !image_digest.match?(DIGEST)
        raise ArgumentError, "Invalid image digest"
      end
      if commit_sha.present? && !commit_sha.match?(COMMIT_SHA)
        raise ArgumentError, "Invalid commit SHA"
      end
      if image_digest.present? && identifier.start_with?("oci:") &&
         !identifier.end_with?("@#{image_digest}")
        raise IdentityConflict, "Artifact identifier does not match image digest"
      end
      if commit_sha.present? && identifier.start_with?("git:") &&
         identifier != "git:#{commit_sha}"
        raise IdentityConflict, "Artifact identifier does not match commit SHA"
      end

      artifact = application.artifacts.find_or_initialize_by(identifier: identifier)
      if artifact.persisted?
        if artifact.kind != kind
          raise IdentityConflict, "Artifact kind cannot change"
        end
        { image_digest: image_digest, commit_sha: commit_sha }.each do |field, value|
          stored = artifact.public_send(field)
          if stored.present? && value.present? && stored != value
            raise IdentityConflict, "#{field} cannot change for an existing artifact"
          end
        end
      end

      artifact.kind = kind
      artifact.image_digest ||= image_digest
      artifact.commit_sha ||= commit_sha
      artifact.save!
      artifact
    end
  end
end
