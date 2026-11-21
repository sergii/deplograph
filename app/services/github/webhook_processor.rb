module Github
  class WebhookProcessor
    def call(event, body)
      case event
      when "installation"
        process_installation(body)
      when "installation_repositories"
        process_repository_change(body)
      when "push"
        process_push(body)
      else
        { ignored: true }
      end
    end

    private

    def process_installation(body)
      action = body.fetch("action")
      installation = body.fetch("installation")
      state = case action
      when "created", "unsuspend", "new_permissions_accepted" then "active"
      when "suspend" then "suspended"
      when "deleted" then "deleted"
      else return { ignored: true }
      end

      record = GithubInstallation.find_or_initialize_by(
        installation_id: installation.fetch("id")
      )
      # A deleted installation ID must not be revived by an old created event.
      return { ignored: true, state: "deleted" } if
        record.persisted? && record.state == "deleted" && state == "active"

      record.assign_attributes(
        account_id: installation.fetch("account").fetch("id"),
        account_login: installation.fetch("account").fetch("login"),
        permissions: installation.fetch("permissions", {}),
        state: state,
        last_event_at: Time.current
      )
      record.save!

      if state != "active" || record.permissions["contents"] != "read"
        record.github_repository_grants.where(enabled: true).update_all(
          enabled: false, sbom_report_uuid: nil, sbom_sync_status: "not_requested"
        )
      else
        Array(body["repositories"]).each { |repo| update_grant(record, repo, true) }
      end
      { installation_id: record.installation_id, state: record.state }
    end

    def process_repository_change(body)
      return { ignored: true } unless body["action"].in?(%w[added removed])

      installation = GithubInstallation.find_by!(
        installation_id: body.fetch("installation").fetch("id")
      )
      raise ArgumentError, "Installation is not active" unless installation.state == "active"

      scheduled = []
      Array(body["repositories_added"]).each do |repo|
        grant = update_grant(installation, repo, true)
        scheduled << grant.github_repository_id if installation.organization_id.present?
      end
      Array(body["repositories_removed"]).each do |repo|
        update_grant(installation, repo, false)
      end
      { installation_id: installation.installation_id, state: installation.state,
        sync_repository_ids: scheduled }
    end

    def process_push(body)
      installation_id = body.dig("installation", "id")
      repo_id = body.dig("repository", "id")
      return { ignored: true } unless installation_id && repo_id

      installation = GithubInstallation.find_by(installation_id: installation_id)
      return { ignored: true } unless installation&.organization_id.present? &&
        installation.state == "active" && installation.permissions["contents"] == "read"

      grant = installation.github_repository_grants.find_by(
        github_repository_id: repo_id, enabled: true
      )
      return { ignored: true } unless grant &&
        grant.full_name.casecmp?(body.dig("repository", "full_name").to_s)

      { installation_id: installation.installation_id,
        sync_repository_ids: [grant.github_repository_id] }
    end

    def update_grant(installation, repo, enabled)
      grant = installation.github_repository_grants.find_or_initialize_by(
        github_repository_id: repo.fetch("id")
      )
      grant.full_name = repo.fetch("full_name")
      grant.enabled = enabled
      unless enabled
        grant.sbom_report_uuid = nil
        grant.sbom_requested_at = nil
        grant.sbom_sync_status = "not_requested"
      end
      grant.save!
      grant
    end
  end
end
