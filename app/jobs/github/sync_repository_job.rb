module Github
  class SyncRepositoryJob < ApplicationJob
    queue_as :default

    MAX_POLL_ATTEMPTS = 8

    def perform(installation_id:, repository_id:, attempt: 0)
      installation = GithubInstallation.find_by(installation_id: installation_id)
      return unless installation&.organization_id.present? && installation.state == "active"

      grant = installation.github_repository_grants.find_by(
        github_repository_id: repository_id, enabled: true
      )
      return unless grant

      result = SbomImporter.new.call(grant: grant)
      if result.status == "pending"
        if attempt < MAX_POLL_ATTEMPTS
          self.class.set(wait: 1.minute).perform_later(
            installation_id: installation_id, repository_id: repository_id,
            attempt: attempt + 1
          )
        else
          grant.update!(sbom_sync_status: "pending", last_import_error:
            "GitHub report still processing; retry the import later")
        end
      end
    rescue SbomImporter::PermissionError
      # Revocation is expected. Never retry with the same access grant.
      Rails.logger.info("GitHub SBOM import access revoked for installation #{installation_id}")
    rescue HttpClient::Error, Inventory::Importer::InvalidDocument, KeyError => error
      Rails.logger.warn("GitHub SBOM import failed for repository ID #{repository_id}: #{error.class}")
    end
  end
end
