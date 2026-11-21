module Api
  module V1
    class FindingsController < BaseController
      def index
        return unless authorize_integration!(permission: "read",
          repository: params[:repository], environment: params[:environment])

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

      private

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
