module Findings
  class VerifyRemediation
    class InvalidComparison < StandardError; end

    def call(finding:, comparison:, trigger: "manual", actor: nil)
      unless FindingVerificationCheck::TRIGGERS.include?(trigger)
        raise InvalidComparison, "Invalid verification trigger"
      end

      verify_scope!(finding, comparison)
      if actor && !Membership.exists?(organization_id: finding.organization_id, user_id: actor.id)
        raise InvalidComparison, "Actor must belong to finding organization"
      end

      finding.with_lock do
        previous = finding.finding_verification_checks.find_by(drift_comparison: comparison)
        next previous if previous

        attempt = finding.remediation_attempts.where(status: "reported_applied")
          .order(created_at: :desc, id: :desc).first
        outcome, reason = decision(finding, comparison, attempt)
        check = finding.finding_verification_checks.create!(
          drift_comparison: comparison,
          remediation_attempt: attempt,
          requested_by: actor, trigger: trigger, outcome: outcome,
          reason_code: reason, checked_at: Time.current,
          authoritative: false,
          evidence_quality: evidence_quality(comparison)
        )
        finding.drift_finding_events.create!(
          actor: actor, drift_comparison: comparison, action: "verification_checked",
          note: "Verification: #{outcome} (#{reason})"
        )
        # No existing collector provides authoritative complete runtime evidence.
        # Candidate-clear must remain verification_pending, never resolved.
        check
      end
    end

    private

    def verify_scope!(finding, comparison)
      unless finding.organization_id == comparison.organization_id &&
             finding.application_id == comparison.application_id &&
             finding.baseline_environment_id == comparison.baseline_environment_id &&
             finding.target_environment_id == comparison.target_environment_id &&
             finding.latest_comparison.mode == comparison.mode
        raise InvalidComparison, "Comparison must match finding tenant, application, environments and mode"
      end
    end

    def decision(finding, comparison, attempt)
      candidates = Findings::Extractor.new.call(comparison)
      if candidates.any? { |candidate| candidate.category == finding.category &&
                            candidate.subject == finding.subject }
        return %w[still_affected issue_still_present]
      end

      dimension = relevant_dimension(finding, comparison)
      return %w[inconclusive no_comparable_evidence] unless dimension.is_a?(Hash)

      # Changing a rule to ignore the problem is not a technical remediation.
      if finding.category == "policy_violation"
        current = Array(dimension["comparisons"]).find do |entry|
          entry.is_a?(Hash) && entry["name"] == finding.subject
        end
        previous = finding.latest_comparison.result.dig(
          "dimensions", "environment_value_fingerprints", "comparisons"
        )
        old = Array(previous).find do |entry|
          entry.is_a?(Hash) && entry["name"] == finding.subject
        end
        return %w[inconclusive no_comparable_evidence] unless current && old
        return %w[policy_changed policy_exception_changed] if
          current["policy"] != old["policy"] || current["evaluation"] == "ignored"
        return %w[inconclusive incomplete_evidence] unless
          current["evaluation"] == "compliant"
      end

      return %w[inconclusive newer_remediation_required] unless attempt
      return %w[inconclusive comparison_precedes_remediation] unless
        comparison.compared_at > attempt.created_at &&
          comparison.compared_at <= Time.current + 30.seconds

      return %w[inconclusive missing_target_evidence] unless
        target_evidence?(finding, attempt, comparison, dimension)

      return %w[inconclusive old_or_stale_evidence] if
        comparison.status == "stale" || dimension["status"] == "stale"
      return %w[inconclusive incomplete_evidence] unless complete?(finding, comparison, dimension)

      %w[candidate_clear fresh_comparison_no_issue]
    end

    def target_evidence?(finding, attempt, comparison, dimension)
      if attempt.deployment
        deployment = attempt.deployment
        return false unless deployment.environment_id == finding.target_environment_id
        return false unless deployment.deployed_at >= finding.first_seen_at &&
                            comparison.compared_at >= deployment.deployed_at

        if comparison.mode == "reported"
          identifier = deployment.artifact.image_digest.presence ||
            deployment.artifact.identifier
          return Array(comparison.result.dig("target", "workloads")).any? do |entry|
            entry.is_a?(Hash) &&
              entry["event_id"].present? && entry["event_id"] == deployment.external_id &&
              entry["artifact_identifier"] == identifier &&
              timestamp_after?(entry["recorded_at"], deployment.deployed_at)
          end
        end

        if %w[configuration_names configuration_fingerprints].include?(comparison.mode)
          snapshot = snapshot_from_dimension(comparison.mode, dimension)
          return snapshot.present? &&
            snapshot.environment_id == finding.target_environment_id &&
            snapshot.collected_at >= deployment.deployed_at &&
            snapshot.collected_at >= attempt.created_at
        end

        false
      elsif attempt.vulnerability_scan_run
        scan = attempt.vulnerability_scan_run
        return false unless scan.status == "completed" &&
          scan.completed_at.present? &&
          scan.completed_at >= finding.first_seen_at &&
          comparison.compared_at >= scan.completed_at

        artifact_id = scan.inventory_snapshot.artifact_id
        return false unless finding.target_environment.deployments
          .where(artifact_id: artifact_id).exists?

        Array(comparison.result.dig("target", "workloads")).any? do |entry|
          entry.is_a?(Hash) &&
            entry["inventory_snapshot_id"] == scan.inventory_snapshot_id &&
            timestamp_after?(entry["scan_completed_at"], scan.completed_at)
        end
      else
        false
      end
    end

    def snapshot_from_dimension(mode, dimension)
      id = if mode == "configuration_names"
        dimension.dig("target", "snapshot_id")
      else
        dimension.dig("target", "snapshot_id")
      end
      ConfigurationSnapshot.find_by(id: id) if id
    end

    def timestamp_after?(value, earliest)
      value.present? && Time.iso8601(value.to_s) >= earliest
    rescue ArgumentError
      false
    end

    def relevant_dimension(finding, comparison)
      dimensions = comparison.result.fetch("dimensions", {})
      name = case finding.category
      when "policy_violation", "fingerprint_gap"
        "environment_value_fingerprints"
      when "env_key_drift", "env_key_evidence_gap"
        "environment_variables"
      when "security_advisory", "security_evidence_gap"
        "security"
      when "release_drift", "release_evidence_gap"
        "release"
      when "artifact_drift", "artifact_evidence_gap"
        "artifact"
      when "dependency_version", "dependency_added", "dependency_removed", "dependencies_evidence_gap"
        "dependencies"
      when "workloads_drift", "workloads_evidence_gap"
        "workloads"
      end
      dimensions[name] if name
    end

    def complete?(finding, comparison, dimension)
      # Observed workloads are not guaranteed complete by today's collectors.
      return false if comparison.mode == "observed"
      return false if %w[unknown stale partial].include?(dimension["status"])
      return false if %w[unknown stale].include?(comparison.status)

      case finding.category
      when "security_advisory", "security_evidence_gap"
        dimension["inventory_coverage"] == "complete" &&
          [comparison.result["baseline"], comparison.result["target"]].all? do |env|
            env.is_a?(Hash) && Array(env["workloads"]).present? &&
              env["workloads"].all? do |workload|
                workload["inventory_coverage"] == "complete" &&
                  workload["scan_status"] == "completed" &&
                  scan_fresh?(workload["scan_completed_at"])
              end
          end
      when "dependency_version", "dependency_added", "dependency_removed", "dependencies_evidence_gap"
        dimension["inventory_coverage"] == "complete"
      when "policy_violation", "fingerprint_gap"
        dimension["confidence"] == "complete" &&
          dimension["values_compared"] == true &&
          Array(dimension["unresolved_keys"]).empty? &&
          dimension["status"] == "same"
      when "env_key_drift", "env_key_evidence_gap"
        dimension["confidence"] == "complete" && dimension["absence_confirmed"] == true
      when "release_drift", "artifact_drift", "release_evidence_gap", "artifact_evidence_gap"
        dimension["status"] == "same"
      else
        false
      end
    end

    def scan_fresh?(timestamp)
      timestamp.present? && Time.iso8601(timestamp.to_s) >=
        Time.current - Drift::Comparator::MAX_ADVISORY_AGE
    rescue ArgumentError
      false
    end

    def evidence_quality(comparison)
      return "stale" if comparison.status == "stale"
      return "unknown" if comparison.status == "unknown"
      return "partial" if comparison.mode == "observed" ||
        comparison.result["confidence"] == "partial"

      "reported_only"
    end
  end
end
