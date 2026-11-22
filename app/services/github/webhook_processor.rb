module Github
  class WebhookProcessor
    def call(event, body)
      case event
      when "installation"
        process_installation(body)
      when "installation_repositories"
        process_repository_change(body)
      else
        { ignored: true }
      end
    end

    private

    def process_installation(body)
      action = body.fetch("action")
      installation = body.fetch("installation")
      state = case action
      when "created", "unsuspend" then "active"
      when "suspend" then "suspended"
      when "deleted" then "deleted"
      else return { ignored: true }
      end

      record = GithubInstallation.find_or_initialize_by(installation_id: installation.fetch("id"))
      record.assign_attributes(
        account_id: installation.fetch("account").fetch("id"),
        account_login: installation.fetch("account").fetch("login"),
        permissions: installation.fetch("permissions", {}),
        state: state,
        last_event_at: Time.current
      )
      record.save!

      if action == "deleted"
        record.github_repository_grants.update_all(enabled: false)
      else
        Array(body["repositories"]).each { |repo| update_grant(record, repo, true) }
      end
      { installation_id: record.installation_id, state: record.state }
    end

    def process_repository_change(body)
      return { ignored: true } unless body["action"] == "added" || body["action"] == "removed"

      installation = GithubInstallation.find_by!(
        installation_id: body.fetch("installation").fetch("id")
      )
      raise ArgumentError, "Installation is not active" unless installation.state == "active"

      Array(body["repositories_added"]).each { |repo| update_grant(installation, repo, true) }
      Array(body["repositories_removed"]).each { |repo| update_grant(installation, repo, false) }
      { installation_id: installation.installation_id, state: installation.state }
    end

    def update_grant(installation, repo, enabled)
      grant = installation.github_repository_grants.find_or_initialize_by(
        github_repository_id: repo.fetch("id")
      )
      grant.full_name = repo.fetch("full_name")
      grant.enabled = enabled
      grant.save!
    end
  end
end
