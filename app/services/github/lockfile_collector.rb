module Github
  class LockfileCollector
    class PermissionError < StandardError; end

    def initialize(app_client: AppClient.new)
      @app_client = app_client
    end

    def call(grant:)
      installation = grant.github_installation
      unless installation.organization_id.present? &&
             installation.state == "active" &&
             grant.enabled? && installation.permissions["contents"] == "read"
        raise PermissionError, "GitHub repository access has been revoked"
      end

      remote = @app_client.installation(installation.installation_id)
      unless remote["id"].to_i == installation.installation_id &&
             remote["app_id"].to_i == Integer(ENV.fetch("GITHUB_APP_ID")) &&
             remote.dig("permissions", "contents") == "read" &&
             remote["suspended_at"].blank?
        raise PermissionError, "GitHub App permissions no longer allow repository inspection"
      end

      token = @app_client.installation_token(
        installation.installation_id, repository_ids: [grant.github_repository_id]
      )
      client = ApiClient.new(token: token)
      repository = client.repository(grant.full_name)
      return nil unless repository
      raise PermissionError, "Repository ID changed" unless
        repository.fetch("id").to_i == grant.github_repository_id

      lockfile = client.file(grant.full_name, "Gemfile.lock",
        ref: repository.fetch("default_branch"))
      return nil unless lockfile

      org = installation.organization
      app = org.applications.find_by(github_repository_id: grant.github_repository_id) ||
        org.applications.find_or_initialize_by(repository_full_name: grant.full_name)
      app.update!(
        name: grant.full_name.split("/").last,
        repository_full_name: grant.full_name,
        github_repository_id: grant.github_repository_id
      )

      Inventory::LockfileImporter.new.call(
        application: app, content: lockfile, source: "github-lockfile"
      )
    end
  end
end
