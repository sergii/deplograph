module Findings
  class RecordRemediation
    class InvalidAttempt < StandardError; end

    def call(finding:, actor:, status:, description:, reference_url: nil,
             release_id: nil, deployment_id: nil, vulnerability_scan_run_id: nil)
      unless Membership.exists?(organization_id: finding.organization_id, user_id: actor.id)
        raise InvalidAttempt, "Actor must belong to the finding organization"
      end
      unless RemediationAttempt::STATUSES.include?(status)
        raise InvalidAttempt, "Unsupported remediation status"
      end

      # Every reference resolves through the finding's application, not a
      # global lookup. DB-level model validation checks cross-evidence lineage.
      release = finding.application.releases.find(release_id) if release_id.present?
      deployment = Deployment.joins(environment: :application)
        .where(applications: { id: finding.application_id }).find(deployment_id) if deployment_id.present?
      scan = VulnerabilityScanRun.joins(inventory_snapshot: { artifact: :application })
        .where(applications: { id: finding.application_id }).find(vulnerability_scan_run_id) if
          vulnerability_scan_run_id.present?

      finding.with_lock do
        attempt = finding.remediation_attempts.create!(
          created_by: actor, status: status, description: description,
          reference_url: reference_url.presence,
          release: release, deployment: deployment, vulnerability_scan_run: scan
        )
        finding.drift_finding_events.create!(
          actor: actor, action: "remediation_recorded",
          note: "Remediation ##{attempt.id} recorded as #{status}"
        )
        attempt
      end
    end
  end
end
