module Api
  module V1
    class IntegrationEventsController < BaseController
      rescue_from Integrations::DeploymentEventIngestor::Conflict, with: :conflict

      def create
        event = Integrations::DeploymentEventIngestor.new.call(payload)
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
