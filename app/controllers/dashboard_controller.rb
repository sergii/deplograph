class DashboardController < ApplicationController
  def index
    @applications = Application.order(:name).includes(:environments)
    @snapshots = InventorySnapshot.includes(artifact: :application).order(created_at: :desc).limit(20)
    @deployments = Deployment.includes(:artifact, :environment).order(deployed_at: :desc).limit(20)
  end
end
