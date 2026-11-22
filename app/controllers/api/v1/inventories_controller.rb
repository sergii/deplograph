module Api
  module V1
    class InventoriesController < BaseController
      rescue_from Inventory::GemfileLock::InvalidLockfile, with: :unprocessable
      def import_lockfile
        body = payload
        return unless authorize_integration!(
          permission: "report", repository: body["repository"],
          provider: body.fetch("source", "api")
        )

        application = application_for(body)
        snapshot = Inventory::LockfileImporter.new.call(
          application: application, content: body.fetch("lockfile"),
          source: body.fetch("source", "api")
        )
        if ENV["OSV_ENABLED"] == "true" && snapshot.match_status == "not_scanned"
          Vulnerabilities::MatchSnapshotJob.perform_later(snapshot.id, trigger: "new_inventory")
        end

        render json: {
          inventory_snapshot_id: snapshot.id,
          artifact_id: snapshot.artifact_id,
          sha256: snapshot.sha256,
          component_count: snapshot.component_occurrences.count,
          dependency_count: snapshot.dependency_edges.count,
          coverage_status: snapshot.coverage_status,
          match_status: snapshot.match_status
        }, status: :created
      end

      def create
        body = payload
        return unless authorize_integration!(
          permission: "report", repository: body["repository"],
          provider: body.fetch("source", "api")
        )
        app = application_for(body)

        snapshot = Inventory::Importer.new.call(
          application: app,
          artifact_identifier: body.fetch("artifact_identifier"),
          kind: body.fetch("artifact_kind", "source"),
          image_digest: body["image_digest"],
          commit_sha: body["commit_sha"],
          document: body.fetch("sbom"),
          format: body.fetch("format"),
          source: body.fetch("source", "api")
        )
        if ENV["OSV_ENABLED"] == "true" && snapshot.match_status == "not_scanned"
          Vulnerabilities::MatchSnapshotJob.perform_later(snapshot.id)
        end

        render json: {
          inventory_snapshot_id: snapshot.id,
          artifact_id: snapshot.artifact_id,
          sha256: snapshot.sha256,
          component_count: snapshot.component_occurrences.count,
          dependency_count: snapshot.dependency_edges.count,
          match_status: snapshot.match_status
        }, status: :created
      end
    end
  end
end
