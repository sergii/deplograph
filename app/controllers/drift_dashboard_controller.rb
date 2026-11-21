class DriftDashboardController < ApplicationController
  layout "operations"

  def index
    @applications = current_organization.applications.order(:name)
    comparisons = current_organization.drift_comparisons
      .includes(:application, :baseline_environment, :target_environment)
    if params[:application_id].present?
      application = @applications.find_by(id: params[:application_id])
      return head :not_found unless application

      comparisons = comparisons.where(application: application)
    end
    @comparisons = comparisons.order(compared_at: :desc, id: :desc).limit(60)
    @open_count = current_organization.drift_findings.unresolved.count
    @evidence_gaps = current_organization.drift_findings.unresolved
      .where(evidence_quality: %w[unknown stale partial]).count
    @application = @applications.find_by(id: params[:application_id])
    @environments = @application ? @application.environments.order(:name) : []
  end

  def show
    @comparison = current_organization.drift_comparisons
      .includes(:application, :baseline_environment, :target_environment)
      .find(params[:id])
    @findings = current_organization.drift_findings
      .where(latest_comparison_id: @comparison.id).order(:priority, :title)
  end

  def create
    return head :forbidden unless can_triage?

    application = current_organization.applications.find(params.require(:application_id))
    mode = params.require(:mode)
    return head :unprocessable_entity unless %w[reported observed].include?(mode)

    comparison = Drift::Comparator.new.call(
      application: application, baseline_name: params.require(:baseline_environment),
      target_name: params.require(:target_environment), mode: mode
    )
    redirect_to drift_comparison_path(comparison),
      notice: "Comparison created from #{mode} evidence"
  rescue ActiveRecord::RecordNotFound
    head :not_found
  rescue ArgumentError
    head :unprocessable_entity
  end

  private

  def can_triage?
    current_user.memberships.find_by(organization_id: current_organization.id)&.role.in?(
      %w[owner admin member]
    )
  end
  helper_method :can_triage?
end
