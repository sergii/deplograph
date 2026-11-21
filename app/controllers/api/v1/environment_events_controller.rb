module Api
  module V1
    class EnvironmentEventsController < BaseController
      def create
        body = payload
        return unless authorize_integration!(
          permission: "report", repository: body["repository"], environment: body["environment"]
        )
        app = application_for(body)
        kind = body.fetch("kind", "other")
        event = body.fetch("event")
        raise ArgumentError, "Expected created or destroyed" unless %w[created destroyed].include?(event)

        environment = app.environments.find_or_initialize_by(name: body.fetch("environment"))
        environment.kind = kind
        environment.external_id = body["external_id"] if body["external_id"].present?
        environment.state = event == "created" ? "active" : "destroyed"
        environment.expires_at = parse_time(body["expires_at"]) if body["expires_at"].present?
        environment.last_reported_at = Time.current
        environment.save!

        render json: {
          environment_id: environment.id, state: environment.state
        }, status: :created
      end
    end
  end
end
