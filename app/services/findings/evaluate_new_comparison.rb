module Findings
  class EvaluateNewComparison
    def call(comparison)
      # Only evaluate tracked remediations. An unrelated new comparison should
      # not create large numbers of speculative verification records.
      DriftFinding.where(
        organization_id: comparison.organization_id,
        application_id: comparison.application_id,
        baseline_environment_id: comparison.baseline_environment_id,
        target_environment_id: comparison.target_environment_id,
        status: "verification_pending"
      ).includes(:latest_comparison).find_each do |finding|
        next unless finding.latest_comparison.mode == comparison.mode
        next unless finding.remediation_attempts.where(status: "reported_applied").exists?

        VerifyRemediation.new.call(
          finding: finding, comparison: comparison, trigger: "new_comparison"
        )
      end
    end
  end
end
