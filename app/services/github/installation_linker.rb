module Github
  class InstallationLinker
    class Forbidden < StandardError; end
    class Conflict < StandardError; end

    def initialize(app_client: AppClient.new)
      @app_client = app_client
    end

    def call(organization:, user:, installation_id:, authorized_installations:)
      id = Integer(installation_id)
      match = authorized_installations.find do |entry|
        entry["id"].to_i == id && entry["app_id"].to_i == Integer(ENV.fetch("GITHUB_APP_ID"))
      end
      raise Forbidden, "Your GitHub authorization does not include this installation" unless match

      remote = @app_client.installation(id)
      unless remote["id"].to_i == id &&
             remote["app_id"].to_i == Integer(ENV.fetch("GITHUB_APP_ID")) &&
             remote.dig("permissions", "contents") == "read" &&
             remote["suspended_at"].blank?
        raise Forbidden, "Installation is inactive or lacks read-only contents permission"
      end

      repositories = @app_client.repositories(id)

      GithubInstallation.transaction do
        installation = GithubInstallation.find_or_initialize_by(installation_id: id)
        if installation.persisted?
          installation.lock!
          if installation.organization_id.present? && installation.organization_id != organization.id
            raise Conflict, "This GitHub installation is already linked to another organization"
          end
          raise Forbidden, "This GitHub installation was deleted" if installation.state == "deleted"
        end

        installation.assign_attributes(
          organization: organization,
          linked_by: user,
          linked_at: installation.linked_at || Time.current,
          account_id: remote.dig("account", "id"),
          account_login: remote.fetch("account").fetch("login"),
          permissions: remote.fetch("permissions"),
          state: "active"
        )
        installation.save!
        RepositorySynchronizer.new.apply!(installation: installation, repositories: repositories)
        installation
      end
    end
  end
end
