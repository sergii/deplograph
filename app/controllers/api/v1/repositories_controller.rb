module Api
  module V1
    class RepositoriesController < BaseController
      def inspect
        body = payload
        return unless authorize_integration!(permission: "read", repository: body["repository"])

        app = application_for(body)
        full_name = app.repository_full_name

        # Never use the global server-side token for tenant-selected repositories.
        # A private repo may only be read through an installation already linked
        # to this organization, granted and active.
        grant = GithubRepositoryGrant.joins(:github_installation)
          .where(full_name: full_name, enabled: true,
            github_installations: {
              organization_id: current_organization.id, state: "active"
            }).first

        token = if grant
          installation = grant.github_installation
          remote = Github::AppClient.new.installation(installation.installation_id)
          unless remote["id"].to_i == installation.installation_id &&
                 remote["app_id"].to_i == Integer(ENV.fetch("GITHUB_APP_ID")) &&
                 remote.dig("permissions", "contents") == "read" &&
                 remote["suspended_at"].blank?
            return render json: { error: "GitHub permission revoked" }, status: :forbidden
          end
          Github::AppClient.new.installation_token(
            installation.installation_id, repository_ids: [grant.github_repository_id]
          )
        end

        client = Github::ApiClient.new(token: token)
        details = Github::RepositoryInspector.new(client: client).call(full_name)
        app.update!(repository_metadata: details, inspected_at: Time.current)
        render json: details
      rescue Github::ApiClient::ApiError, Github::HttpClient::Error
        render json: { error: "GitHub API unavailable or repository not accessible" },
          status: :bad_gateway
      end
    end
  end
end
