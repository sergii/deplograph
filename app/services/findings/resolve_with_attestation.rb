module Findings
  class ResolveWithAttestation
    # An approved, signed control-plane inventory with a pinned workload contract
    # may resolve *artifact drift only*. It never declares CVEs or ENV values fixed.
    def call(attestation)
      attestor = attestation.runtime_attestor
      return [] unless attestor.active? && attestor.resolution_enabled &&
        attestation.complete? &&
        attestation.observed_at >= Time.current - Runtime::AttestationProtocol::MAX_AGE &&
        attestor.environment.state == "active" &&
        attestation.observed_at <= Time.current

      # Do not close findings from out-of-order or same-timestamp observations.
      # Any newer or concurrent report, including incomplete or contradictory
      # evidence, makes this snapshot unsuitable for authoritative resolution.
      # Acceptance is serialized on the environment row by AcceptAttestation.
      superseded = RuntimeAttestation.joins(:runtime_attestor)
        .where(runtime_attestors: {
          organization_id: attestor.organization_id,
          application_id: attestor.application_id,
          environment_id: attestor.environment_id
        })
        .where("runtime_attestations.observed_at >= ?", attestation.observed_at)
        .where.not(id: attestation.id)
        .exists?
      return [] if superseded

      resolved = []
      DriftFinding.where(
        organization_id: attestor.organization_id,
        application_id: attestor.application_id,
        target_environment_id: attestor.environment_id,
        category: "artifact_drift",
        status: "verification_pending"
      ).find_each do |finding|
        finding.with_lock do
          check = finding.finding_verification_checks
            .where(outcome: "candidate_clear").order(checked_at: :desc, id: :desc).first
          next unless check && check.remediation_attempt&.deployment
          deployment = check.remediation_attempt.deployment
          next unless deployment.environment_id == attestor.environment_id
          next unless deployment.artifact.image_digest == attestation.image_digest
          next unless deployment.deployed_at <= attestation.observed_at
          next unless check.checked_at <= attestation.verified_at
          next unless check.drift_comparison.compared_at <= attestation.observed_at

          latest_comparison = finding.application.drift_comparisons.where(
            baseline_environment: finding.baseline_environment,
            target_environment: finding.target_environment,
            mode: "reported"
          ).order(compared_at: :desc, id: :desc).first
          next unless latest_comparison&.id == check.drift_comparison_id
          dimension = latest_comparison.result.dig("dimensions", "artifact")
          next unless dimension.is_a?(Hash) && dimension["status"] == "same" &&
            dimension["baseline"] == [attestation.image_digest] &&
            dimension["target"] == [attestation.image_digest]
          next unless latest_comparison.result["verified_runtime"] == false
          next unless finding.latest_comparison.mode == "reported"
          next if finding.first_seen_at > check.drift_comparison.compared_at

          evidence = finding.finding_resolutions.create!(
            runtime_attestation: attestation,
            finding_verification_check: check,
            remediation_attempt: check.remediation_attempt,
            resolved_at: Time.current
          )
          previous = finding.status
          finding.update!(status: "resolved", resolved_at: evidence.resolved_at,
            evidence_quality: "verified")
          finding.drift_finding_events.create!(
            drift_comparison: latest_comparison,
            action: "verified_resolution", from_status: previous, to_status: "resolved",
            note: "Signed control-plane attestation ##{attestation.id}; full registered workload coverage"
          )
          resolved << evidence
        end
      end
      resolved
    end
  end
end
