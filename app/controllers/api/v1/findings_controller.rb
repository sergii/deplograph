module Api
  module V1
    class FindingsController < BaseController
      rescue_from ActiveRecord::RecordNotFound do
        render json: { error: "Finding not found" }, status: :not_found
      end
      def index
        # Restrict the SQL relation by credential scopes before pagination.
        # A scoped read credential can list its own findings without explicitly
        # repeating repository/environment filter parameters.
        return unless authorize_integration!(permission: "read",
          repository: params[:repository].presence || current_credential.repository_scopes.first,
          environment: params[:environment].presence || current_credential.environment_scopes.first)

        findings = current_organization.drift_findings
          .includes(:application, :baseline_environment, :target_environment)
          .joins(:application).order(last_seen_at: :desc, id: :desc)

        if current_credential.repository_scopes.any?
          findings = findings.where(applications: {
            repository_full_name: current_credential.repository_scopes
          })
        end
        if params[:repository].present?
          findings = findings.where(applications: { repository_full_name: params[:repository] })
        end
        allowed_environments = current_credential.environment_scopes
        if allowed_environments.any?
          ids = Environment.joins(:application)
            .where(applications: { organization_id: current_organization.id },
              name: allowed_environments).select(:id)
          findings = findings.where(baseline_environment_id: ids, target_environment_id: ids)
        end
        if params[:status].present?
          return head :unprocessable_entity unless DriftFinding::STATUSES.include?(params[:status])

          findings = findings.where(status: params[:status])
        end
        render json: { findings: findings.limit(100).map { |finding| present(finding) } }
      end

      def show
        finding = current_organization.drift_findings
          .includes(:application, :baseline_environment, :target_environment)
          .find(params[:id])
        unless current_credential.permits?(permission: "read",
          repository: finding.application.repository_full_name,
          environment: finding.baseline_environment.name) &&
               current_credential.permits?(permission: "read",
                 repository: finding.application.repository_full_name,
                 environment: finding.target_environment.name)
          return head :forbidden
        end
        render json: present(finding)
      end


      def remediations
        finding = scoped_finding(params[:id])
        return if performed?

        entries = finding.remediation_attempts
          .order(created_at: :desc, id: :desc).limit(100)
        render json: {
          remediations: entries.map do |attempt|
            {
              id: attempt.id, status: attempt.status, description: attempt.description,
              reference_url: attempt.reference_url, release_id: attempt.release_id,
              deployment_id: attempt.deployment_id,
              vulnerability_scan_run_id: attempt.vulnerability_scan_run_id,
              created_at: attempt.created_at
            }
          end
        }
      end

      def verifications
        finding = scoped_finding(params[:id])
        return if performed?

        entries = finding.finding_verification_checks
          .order(checked_at: :desc, id: :desc).limit(100)
        render json: {
          verifications: entries.map do |check|
            {
              id: check.id, comparison_id: check.drift_comparison_id,
              remediation_attempt_id: check.remediation_attempt_id,
              trigger: check.trigger, outcome: check.outcome,
              reason_code: check.reason_code, evidence_quality: check.evidence_quality,
              authoritative: false, checked_at: check.checked_at
            }
          end
        }
      end

      private

      def scoped_finding(id)
        finding = current_organization.drift_findings
          .includes(:application, :baseline_environment, :target_environment).find(id)
        repo = finding.application.repository_full_name
        unless current_credential.permits?(permission: "read", repository: repo,
                 environment: finding.baseline_environment.name) &&
               current_credential.permits?(permission: "read", repository: repo,
                 environment: finding.target_environment.name)
          render json: { error: "Insufficient credential scope" }, status: :forbidden
          return nil
        end
        finding
      end

      def present(finding)
        {
          id: finding.id, repository: finding.application.repository_full_name,
          baseline_environment: finding.baseline_environment.name,
          target_environment: finding.target_environment.name,
          category: finding.category, subject: finding.subject,
          title: finding.title, status: finding.status,
          severity: finding.severity, priority: finding.priority,
          evidence_quality: finding.evidence_quality,
          latest_comparison_id: finding.latest_comparison_id,
          first_seen_at: finding.first_seen_at, last_seen_at: finding.last_seen_at,
          assigned_to_id: finding.assigned_to_id, next_action: finding.next_action
        }
      end
    end
  end
end
