module Github
  class ImportsController < ApplicationController
    before_action :require_manager

    def create
      installation = current_organization.github_installations.find_by!(
        installation_id: params.require(:installation_id)
      )
      grant = installation.github_repository_grants.find_by!(
        github_repository_id: params.require(:repository_id), enabled: true
      )
      return head :forbidden unless installation.state == "active"

      job = SyncRepositoryJob.perform_later(
        installation_id: installation.installation_id,
        repository_id: grant.github_repository_id
      )
      return head :service_unavailable unless job

      grant.update!(sbom_sync_status: "pending", last_import_error: nil)
      if request.format.json?
        render json: { status: "queued", repository: grant.full_name }, status: :accepted
      else
        redirect_to github_installations_path,
          notice: "Repository inventory queued. Status updates appear here automatically."
      end
    end

    private

    def require_manager
      membership = current_user.memberships.find_by(organization_id: current_organization.id)
      head :forbidden unless membership&.role.in?(%w[owner admin])
    end
  end
end
