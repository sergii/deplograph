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
      result = SbomImporter.new.call(grant: grant)
      if request.format.json?
        render json: { status: result.status, inventory_snapshot_id: result.snapshot_id },
          status: result.status == "pending" ? :accepted : :created
      else
        redirect_to github_installations_path,
          notice: result.status == "pending" ? "SBOM is processing. Retry import to fetch it." : "SBOM imported."
      end
    rescue SbomImporter::PermissionError
      head :forbidden
    rescue HttpClient::Error, Inventory::Importer::InvalidDocument
      head :bad_gateway
    end

    private

    def require_manager
      membership = current_user.memberships.find_by(organization_id: current_organization.id)
      head :forbidden unless membership&.role.in?(%w[owner admin])
    end
  end
end
