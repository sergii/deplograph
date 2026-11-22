module Api
  module V1
    class IntegrationEventsController < BaseController
      skip_before_action :authenticate_ingestion!
      before_action :authenticate_event!

      rescue_from Integrations::DeploymentEventIngestor::Conflict, with: :conflict

      OBSERVER_TOKEN_ENV = {
        "kubernetes" => "DEPLOGRAPH_KUBERNETES_OBSERVER_TOKEN",
        "kamal_agent" => "DEPLOGRAPH_KAMAL_AGENT_OBSERVER_TOKEN",
        "docker_agent" => "DEPLOGRAPH_DOCKER_AGENT_OBSERVER_TOKEN",
        "aws_ecs" => "DEPLOGRAPH_AWS_ECS_OBSERVER_TOKEN"
      }.freeze

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

      def authenticate_event!
        body = payload

        if body["event_type"] == "artifact.observed"
          source = body["source"]
          env_name = OBSERVER_TOKEN_ENV[source]
          raise ArgumentError, "Only trusted runtime collectors can report observations" unless env_name

          token = ENV[env_name]
          if token.blank?
            render json: { error: "Runtime collector is not configured" }, status: :service_unavailable
            return
          end

          supplied = request.authorization.to_s.delete_prefix("Bearer ")
          unless supplied.bytesize == token.bytesize &&
                 ActiveSupport::SecurityUtils.secure_compare(supplied, token)
            render json: { error: "Unauthorized runtime collector" }, status: :unauthorized
          end
        else
          authenticate_ingestion!
        end
      end

      def conflict(error)
        render json: { error: error.message }, status: :conflict
      end
    end
  end
end
