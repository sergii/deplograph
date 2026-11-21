module Api
  module V1
    class RepositoriesController < BaseController
      def inspect
        body = payload
        return unless authorize_integration!(permission: "read", repository: body["repository"])
        app = application_for(body)
        # Until GitHub App installation tokens are scoped to a tenant, never use
        # a shared server-side GitHub token to inspect caller-selected repositories.
        client = Github::ApiClient.new(token: nil)
        details = Github::RepositoryInspector.new(client: client).call(app.repository_full_name)
        app.update!(repository_metadata: details, inspected_at: Time.current)

        render json: details
      rescue Github::ApiClient::ApiError => error
        render json: { error: error.message }, status: :bad_gateway
      end
    end
  end
end
