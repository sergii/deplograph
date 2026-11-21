module Github
  class RepositorySynchronizer
    class PermissionError < StandardError; end

    def initialize(app_client: AppClient.new)
      @app_client = app_client
    end

    def call(installation:)
      raise PermissionError, "GitHub installation is not connected" unless
        installation.organization_id.present? && installation.state == "active"

      remote = @app_client.installation(installation.installation_id)
      unless remote["id"].to_i == installation.installation_id &&
             remote["app_id"].to_i == Integer(ENV.fetch("GITHUB_APP_ID")) &&
             remote.dig("permissions", "contents") == "read" &&
             remote["suspended_at"].blank?
        raise PermissionError, "GitHub App permission has been revoked"
      end

      repositories = @app_client.repositories(installation.installation_id)
      installation.with_lock do
        raise PermissionError, "GitHub installation disabled" unless installation.state == "active"

        apply!(installation: installation, repositories: repositories)
      end
    end

    def apply!(installation:, repositories:)
      verified = repositories.map do |repo|
        id = Integer(repo.fetch("id"))
        name = repo.fetch("full_name")
        unless name.is_a?(String) && name.match?(/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/)
          raise ArgumentError, "Invalid repository from GitHub"
        end
        [id, name]
      end
      raise ArgumentError, "Duplicate GitHub repository IDs" unless verified.map(&:first).uniq.size == verified.size

      ids = verified.map(&:first)
      installation.github_repository_grants.where.not(github_repository_id: ids)
        .where(enabled: true).update_all(enabled: false, sbom_report_uuid: nil,
          sbom_sync_status: "not_requested", updated_at: Time.current)

      verified.each do |id, full_name|
        grant = installation.github_repository_grants.find_or_initialize_by(github_repository_id: id)
        if grant.persisted? && grant.full_name != full_name
          grant.sbom_report_uuid = nil
          grant.sbom_sync_status = "not_requested"
        end
        grant.update!(full_name: full_name, enabled: true)
      end
      installation.update!(last_synced_at: Time.current, last_sync_error: nil)
      verified.size
    end
  end
end
