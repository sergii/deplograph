module Api
  module V1
    class IntegrationEventsController < BaseController
      rescue_from Integrations::DeploymentEventIngestor::Conflict, with: :conflict

      def create
        body = payload
        permission = body["event_type"] == "artifact.observed" ? "observe" : "report"
        return unless authorize_integration!(
          permission: permission, repository: body["repository"],
          environment: body["environment"], provider: body["source"]
        )

        event = Integrations::DeploymentEventIngestor.new.call(
          body, organization: current_organization
        )
        render json: {
          event_id: event.event_id,
          source: event.source,
          event_type: event.event_type,
          environment_id: event.environment_id,
          deployment_id: event.deployment_id
        }, status: :accepted
      end

      private

      def conflict(error)
        render json: { error: error.message }, status: :conflict
      end
    end
  end
end
