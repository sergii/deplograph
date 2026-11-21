class FindingsController < ApplicationController
  layout "operations"

  def index
    @applications = current_organization.applications.order(:name)
    @findings = current_organization.drift_findings
      .includes(:application, :baseline_environment, :target_environment, :assigned_to)
    if params[:application_id].present?
      application = @applications.find_by(id: params[:application_id])
      return head :not_found unless application

      @findings = @findings.where(application: application)
    end

    {
      status: DriftFinding::STATUSES,
      severity: DriftFinding::SEVERITIES,
      priority: DriftFinding::PRIORITIES
    }.each do |field, values|
      value = params[field]
      return head :unprocessable_entity if value.present? && !values.include?(value)

      @findings = @findings.where(field => value) if value.present?
    end
    @total_open = current_organization.drift_findings.unresolved.count
    @total_unknown = current_organization.drift_findings.unresolved
      .where(evidence_quality: %w[unknown stale partial]).count
    @findings = @findings.order(:priority, last_seen_at: :desc).limit(100)
  end

  def show
    @finding = scoped_findings.includes(
      :application, :baseline_environment, :target_environment, :latest_comparison, :assigned_to
    ).find(params[:id])
    @history = @finding.drift_finding_events
      .includes(:actor, :drift_comparison).order(created_at: :desc, id: :desc).limit(100)
    @members = current_organization.users.order(:email)
  end

  def update
    return head :forbidden unless can_triage?

    finding = scoped_findings.find(params[:id])
    fields = params.permit(:status, :note, :assigned_to_id, :next_action, :priority, :severity)
    changed = fields.to_h.symbolize_keys
    changed[:assigned_to_id] = nil if fields.key?(:assigned_to_id) &&
                                 fields[:assigned_to_id].blank?
    unless can_classify? || (fields.keys & %w[priority severity]).empty?
      return head :forbidden
    end

    Findings::UpdateFinding.new.call(finding: finding, actor: current_user, **changed)
    redirect_to finding_path(finding), notice: "Finding updated"
  rescue Findings::UpdateFinding::TransitionDenied, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound
    head :unprocessable_entity
  end

  private

  def scoped_findings
    current_organization.drift_findings
  end

  def current_role
    current_user.memberships.find_by(organization_id: current_organization.id)&.role
  end

  def can_triage?
    %w[owner admin member].include?(current_role)
  end

  def can_classify?
    %w[owner admin].include?(current_role)
  end

  helper_method :can_triage?, :can_classify?
end
