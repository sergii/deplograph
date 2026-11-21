class FindingsController < ApplicationController
  layout "operations"

  rescue_from ActiveRecord::RecordNotFound do
    head :not_found
  end

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
    @remediations = @finding.remediation_attempts
      .includes(:created_by, :release, :deployment, :vulnerability_scan_run)
      .order(created_at: :desc, id: :desc).limit(30)
    @verification_checks = @finding.finding_verification_checks
      .includes(:drift_comparison, :remediation_attempt, :requested_by)
      .order(checked_at: :desc, id: :desc).limit(30)
    @candidate_comparisons = current_organization.drift_comparisons
      .where(application: @finding.application,
        baseline_environment: @finding.baseline_environment,
        target_environment: @finding.target_environment,
        mode: @finding.latest_comparison.mode)
      .order(compared_at: :desc, id: :desc).limit(30)
    @candidate_deployments = @finding.application.environments
      .where(id: [@finding.baseline_environment_id, @finding.target_environment_id])
      .flat_map { |environment| environment.deployments.includes(:artifact).order(deployed_at: :desc).limit(30).to_a }
    @candidate_scans = VulnerabilityScanRun
      .joins(inventory_snapshot: { artifact: :application })
      .where(applications: { id: @finding.application_id })
      .order(started_at: :desc, id: :desc).limit(30)
    @candidate_releases = @finding.application.releases.order(id: :desc).limit(30)
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

    Findings::UpdateFinding.new.call(finding: finding, actor: current_user,
      can_classify: can_classify?, **changed)
    redirect_to finding_path(finding), notice: "Finding updated"
  rescue Findings::UpdateFinding::TransitionDenied, ActiveRecord::RecordInvalid
    head :unprocessable_entity
  end


  def record_remediation
    return head :forbidden unless can_triage?

    finding = scoped_findings.find(params[:id])
    allowed = params.permit(:status, :description, :reference_url,
      :release_id, :deployment_id, :vulnerability_scan_run_id)
    Findings::RecordRemediation.new.call(
      finding: finding, actor: current_user, **allowed.to_h.symbolize_keys
    )
    redirect_to finding_path(finding), notice: "Remediation evidence recorded"
  rescue Findings::RecordRemediation::InvalidAttempt, ActiveRecord::RecordInvalid
    head :unprocessable_entity
  end

  def verify
    return head :forbidden unless can_triage?

    finding = scoped_findings.find(params[:id])
    comparison = current_organization.drift_comparisons.find(params.require(:comparison_id))
    check = Findings::VerifyRemediation.new.call(
      finding: finding, comparison: comparison, trigger: "manual",
      actor: current_user
    )
    redirect_to finding_path(finding), notice: "Verification check: #{check.outcome.humanize}"
  rescue Findings::VerifyRemediation::InvalidComparison
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
