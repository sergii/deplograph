module Integrations
  class DeploymentEventIngestor
    class Conflict < StandardError; end

    SOURCES = %w[github_actions kamal kubernetes kamal_agent docker_agent aws_ecs].freeze
    OBSERVERS = %w[kubernetes kamal_agent docker_agent aws_ecs].freeze
    TYPES = %w[deployment.reported artifact.observed].freeze
    MAX_EVENT_AGE = 365.days

    def call(body)
      source = body.fetch("source")
      type = body.fetch("event_type")
      raise ArgumentError, "Unsupported source" unless SOURCES.include?(source)
      raise ArgumentError, "Unsupported event type" unless TYPES.include?(type)
      if type == "artifact.observed" && !OBSERVERS.include?(source)
        raise ArgumentError, "CI is not an independent runtime observer"
      end

      event_id = body.fetch("event_id")
      raise ArgumentError, "Invalid event ID" unless event_id.is_a?(String) &&
        event_id.match?(%r{\A[-\w.:/]{1,160}\z})

      occurred = Time.iso8601(body.fetch("occurred_at"))
      raise ArgumentError, "Event timestamp is outside allowed window" if
        occurred < Time.current - MAX_EVENT_AGE || occurred > Time.current + 5.minutes

      repository = body.fetch("repository")
      raise ArgumentError, "Invalid repository" unless repository.match?(/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/)
      name = body.fetch("environment")
      raise ArgumentError, "Invalid environment name" unless name.match?(/\A[a-zA-Z0-9_.-]{1,120}\z/)

      ApplicationRecord.transaction do
        app = Application.find_or_create_by!(repository_full_name: repository) do |record|
          record.name = repository.split("/").last
        end

        environment = app.environments.find_or_initialize_by(name: name)
        if environment.persisted? && environment.state == "destroyed"
          raise Conflict, "Environment destroyed; explicit recreation is required"
        end
        environment.kind = body.fetch("environment_kind", infer_kind(name))
        environment.save!

        existing = environment.deployment_events.find_by(source: source, event_id: event_id)
        if existing
          raise Conflict, "Event ID already used with different payload" unless existing.payload == body
          next existing
        end

        digest = body["image_digest"]
        if digest.present? && !digest.match?(/\Asha256:[a-f0-9]{64}\z/)
          raise ArgumentError, "Invalid image digest"
        end

        artifact = resolve_artifact(app, body, digest)
        release = app.releases.find_by(name: body["release"]) if body["release"].present?
        if body["release"].present? && !release
          raise ArgumentError, "Unknown release"
        end
        if release && artifact && !release.release_artifacts.exists?(artifact: artifact)
          raise Conflict, "Artifact is not part of release"
        end

        deployment = resolve_deployment(environment, artifact, release, source, type, body, occurred)

        event = environment.deployment_events.create!(
          deployment: deployment, source: source, event_id: event_id,
          event_type: type, occurred_at: occurred, payload: body
        )

        if type == "artifact.observed"
          raise ArgumentError, "Image digest required" if digest.blank?
          workload = body.fetch("workload")
          raise ArgumentError, "Invalid workload" unless workload.match?(%r{\A[-\w./]{1,150}\z})

          environment.deployment_observations.create!(
            deployment: deployment, artifact: artifact, source: source,
            event_id: event_id, workload: workload, image_digest: digest,
            observed_at: occurred, metadata: body.fetch("metadata", {})
          )
          if environment.last_observed_at.nil? || occurred > environment.last_observed_at
            environment.update!(last_observed_at: occurred)
          end
          if deployment && deployment.artifact.image_digest == digest
            if deployment.observed_at.nil? || occurred > deployment.observed_at
              deployment.update!(observed_at: occurred, status: "observed")
            end
          end
        elsif environment.last_reported_at.nil? || occurred > environment.last_reported_at
          environment.update!(last_reported_at: occurred)
        end

        event
      end
    end

    private

    def resolve_artifact(app, body, digest)
      return nil if digest.blank? && body["commit_sha"].blank?

      identifier = body["artifact_identifier"].presence ||
        (digest ? "oci:#{body.fetch("image")}@#{digest}" : "git:#{body.fetch("commit_sha")}")
      artifact = app.artifacts.find_or_initialize_by(identifier: identifier)
      if artifact.persisted? && artifact.image_digest.present? && artifact.image_digest != digest
        raise Conflict, "Artifact digest mismatch"
      end
      artifact.assign_attributes(
        kind: digest ? "image" : "source",
        image_digest: digest,
        commit_sha: body["commit_sha"].presence || artifact.commit_sha
      )
      artifact.save!
      artifact
    end

    def resolve_deployment(environment, artifact, release, source, type, body, occurred)
      id = body["deployment_id"]
      if type == "deployment.reported"
        raise ArgumentError, "Deployment ID required" if id.blank?
        raise ArgumentError, "Artifact required" unless artifact
      end
      return nil if id.blank?

      deployment = environment.deployments.find_or_initialize_by(external_id: id)
      if deployment.persisted?
        if type == "deployment.reported" && artifact && deployment.artifact_id != artifact.id
          raise Conflict, "Deployment ID already refers to another artifact"
        end
        if release && deployment.release_id.present? && deployment.release_id != release.id
          raise Conflict, "Deployment ID already refers to another release"
        end
        deployment.update!(release: release) if release && deployment.release_id.nil?
      else
        return nil if type == "artifact.observed"

        deployment.assign_attributes(
          artifact: artifact, release: release, provider: source,
          status: "reported", commit_sha: body["commit_sha"],
          deployed_at: occurred
        )
        deployment.save!
      end
      deployment
    end

    def infer_kind(name)
      return name if %w[production staging sandbox test preview development other].include?(name)
      name.start_with?("preview") ? "preview" : "other"
    end
  end
end
