module Api
  module V1
    class DeploymentsController < BaseController
      rescue_from Integrations::DeploymentEventIngestor::Conflict, with: :conflict

      def create
        body = payload
        provider = body.fetch("provider", "ci")
        return unless authorize_integration!(
          permission: "report", repository: body["repository"],
          environment: body["environment"], provider: provider
        )
        identifier = body.fetch("deployment_id")
        raise ArgumentError, "Missing deployment ID" if identifier.blank?

        event_payload = body.merge(
          "source" => provider,
          "event_id" => "legacy:#{identifier}",
          "event_type" => "deployment.reported",
          "occurred_at" => body.fetch("deployed_at")
        )
        event = Integrations::DeploymentEventIngestor.new.call(event_payload, organization: current_organization)
        deployment = event.deployment

        render json: {
          deployment_id: deployment.id,
          environment_id: event.environment_id,
          artifact_id: deployment.artifact_id,
          evidence: "reported",
          message: "Deployment received; runtime not independently verified"
        }, status: :created
      end

      private

      def conflict(error)
        render json: { error: error.message }, status: :conflict
      end
    end
  end
end
