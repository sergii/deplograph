module Api
  module V1
    class DeploymentsController < BaseController
      def create
        body = payload
        app = application_for(body)
        name = body.fetch("environment")
        identifier = body.fetch("deployment_id")
        raise ArgumentError, "Missing deployment ID" if identifier.blank?

        environment = app.environments.find_or_initialize_by(name: name)
        environment.assign_attributes(
          kind: body.fetch("environment_kind", infer_kind(name)),
          state: "active",
          last_reported_at: Time.current
        )
        environment.save!

        image_digest = body["image_digest"]
        if image_digest.present? && !image_digest.match?(/\Asha256:[a-f0-9]{64}\z/)
          raise ArgumentError, "Invalid image digest"
        end
        artifact_id = body["artifact_identifier"].presence ||
          (image_digest.present? ? "oci:#{body.fetch("image")}@#{image_digest}" : "git:#{body.fetch("commit_sha")}")
        artifact = app.artifacts.find_or_initialize_by(identifier: artifact_id)
        artifact.assign_attributes(
          kind: image_digest.present? ? "image" : "source",
          image_digest: image_digest,
          commit_sha: body["commit_sha"]
        )
        artifact.save!

        deployment = environment.deployments.find_or_initialize_by(external_id: identifier)
        deployment.assign_attributes(
          artifact: artifact,
          provider: body.fetch("provider", "ci"),
          status: "reported",
          commit_sha: body["commit_sha"],
          deployed_at: parse_time(body.fetch("deployed_at")),
          metadata: body.fetch("metadata", {})
        )
        deployment.save!

        render json: {
          deployment_id: deployment.id,
          environment_id: environment.id,
          artifact_id: artifact.id,
          evidence: "reported",
          message: "Deployment received; runtime not independently verified"
        }, status: :created
      end

      private

      def infer_kind(name)
        return name if Environment.new(kind: name).valid?(:kind)
        return "preview" if name.start_with?("preview")

        "other"
      end
    end
  end
end
