module Api
  module V1
    class ReleasesController < BaseController
      rescue_from Releases::Registrar::Conflict, with: :conflict

      def create
        body = payload
        return unless authorize_integration!(
          permission: "report", repository: body["repository"],
          provider: body.dig("build", "provider")
        )

        release = Releases::Registrar.new.call(body, organization: current_organization)
        render json: {
          id: release.id,
          repository: release.application.repository_full_name,
          release: release.name,
          commit_sha: release.source_revision.commit_sha,
          artifacts: release.artifacts.order(:identifier).pluck(:identifier)
        }, status: :created
      end

      def index
        repository = params.require(:repository)
        return unless authorize_integration!(permission: "read", repository: repository)
        application = current_organization.applications.find_by!(repository_full_name: repository)
        render json: {
          releases: application.releases.order(created_at: :desc).limit(100).map do |release|
            { name: release.name, commit_sha: release.source_revision&.commit_sha,
              artifacts: release.artifacts.pluck(:identifier) }
          end
        }
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Repository not found" }, status: :not_found
      end

      private

      def conflict(error)
        render json: { error: error.message }, status: :conflict
      end
    end
  end
end
