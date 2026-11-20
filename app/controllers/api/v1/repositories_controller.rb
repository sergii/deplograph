module Api
  module V1
    class RepositoriesController < BaseController
      def inspect
        body = payload
        app = application_for(body)
        details = Github::RepositoryInspector.new.call(app.repository_full_name)
        app.update!(repository_metadata: details, inspected_at: Time.current)

        render json: details
      rescue Github::ApiClient::ApiError => error
        render json: { error: error.message }, status: :bad_gateway
      end
    end
  end
end
