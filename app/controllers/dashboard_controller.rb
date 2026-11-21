class DashboardController < ApplicationController
  def index
    @applications = current_organization.applications.order(:name).includes(:environments)
    @snapshots = InventorySnapshot
      .joins(artifact: :application)
      .where(applications: { organization_id: current_organization.id })
      .includes(artifact: :application).order(created_at: :desc).limit(20)
    @deployments = Deployment
      .joins(environment: :application)
      .where(applications: { organization_id: current_organization.id })
      .includes(:artifact, :environment).order(deployed_at: :desc).limit(20)
  end
end
