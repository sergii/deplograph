require "uri"

module Github
  class SbomImporter
    class PermissionError < StandardError; end
    Result = Data.define(:status, :snapshot_id)

    REPORT_URL = %r{\Ahttps://api\.github\.com/repos/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/dependency-graph/sbom/fetch-report/([0-9a-fA-F-]{36})\z}

    def initialize(app_client: AppClient.new)
      @app_client = app_client
    end

    def call(grant:)
      installation = grant.github_installation
      raise PermissionError, "Repository access revoked" unless
        installation.organization_id.present? && installation.state == "active" && grant.enabled? &&
        installation.permissions["contents"] == "read"

      remote = @app_client.installation(installation.installation_id)
      unless remote["id"].to_i == installation.installation_id &&
             remote["app_id"].to_i == Integer(ENV.fetch("GITHUB_APP_ID")) &&
             remote["suspended_at"].blank? && remote.dig("permissions", "contents") == "read"
        raise PermissionError, "GitHub installation permission revoked"
      end

      # A GitHub installation token is scoped to the one repository being read.
      token = @app_client.installation_token(
        installation.installation_id, repository_ids: [grant.github_repository_id]
      )
      client = HttpClient.new(token: token)
      path = "/repos/#{grant.full_name}/dependency-graph/sbom"
      uuid = grant.sbom_report_uuid
      if uuid.present? && grant.sbom_requested_at.present? && grant.sbom_requested_at < 6.days.ago
        uuid = nil
      end

      if uuid.blank?
        generated = client.get("#{path}/generate-report")
        raise HttpClient::Error, "GitHub did not accept SBOM generation" unless generated.status == 201

        url = generated.body.fetch("sbom_url")
        parsed = url.match(REPORT_URL)
        raise HttpClient::Error, "Unexpected GitHub report location" unless
          parsed && "#{parsed[1]}/#{parsed[2]}".casecmp?(grant.full_name)

        uuid = parsed[3].downcase
        grant.update!(sbom_report_uuid: uuid, sbom_requested_at: Time.current,
          sbom_sync_status: "pending",
          last_import_error: nil)
      end

      result = client.get("#{path}/fetch-report/#{uuid}")
      return Result.new(status: "pending", snapshot_id: nil) if result.status == 202

      document = if result.status == 302
        HttpClient.download(result.location)
      elsif result.status == 200
        result.body
      else
        raise HttpClient::Error, "Unexpected SBOM report status"
      end

      spdx = document.fetch("sbom", document)
      raise HttpClient::Error, "GitHub did not return SPDX" unless
        spdx.is_a?(Hash) && spdx["spdxVersion"].to_s.start_with?("SPDX-2.")

      organization = installation.organization
      application = organization.applications.find_or_create_by!(
        repository_full_name: grant.full_name
      ) { |app| app.name = grant.full_name.split("/").last }

      # GitHub dependency-graph exports are not build attestations. Do not claim
      # their contents correspond to a verified commit or deployed OCI image.
      snapshot = Inventory::Importer.new.call(
        application: application, artifact_identifier: "github-sbom:#{installation.installation_id}:#{uuid}",
        document: spdx, format: "spdx", kind: "source", source: "github"
      )

      grant.update!(sbom_report_uuid: nil, sbom_requested_at: nil,
        sbom_sync_status: "completed",
        last_imported_at: Time.current, last_import_error: nil)
      if ENV["OSV_ENABLED"] == "true" && snapshot.match_status == "not_scanned"
        Vulnerabilities::MatchSnapshotJob.perform_later(snapshot.id)
      end
      Result.new(status: "completed", snapshot_id: snapshot.id)
    rescue HttpClient::Error, Inventory::Importer::InvalidDocument, KeyError => error
      if grant.persisted? && grant.enabled?
        grant.update!(sbom_sync_status: "failed", last_import_error: error.message.truncate(500))
      end
      raise
    end
  end
end
