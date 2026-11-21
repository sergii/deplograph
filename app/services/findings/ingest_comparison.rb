require "digest"

module Findings
  class IngestComparison
    def call(comparison)
      Extractor.new.call(comparison).each do |candidate|
        key = Digest::SHA256.hexdigest([
          comparison.application_id,
          comparison.baseline_environment_id,
          comparison.target_environment_id,
          comparison.mode,
          candidate.category,
          candidate.subject
        ].join("\0"))

        finding = DriftFinding.find_or_initialize_by(
          organization: comparison.organization, fingerprint: key
        )
        if finding.new_record?
          finding.assign_attributes(
            application: comparison.application,
            baseline_environment: comparison.baseline_environment,
            target_environment: comparison.target_environment,
            category: candidate.category, subject: candidate.subject,
            title: candidate.title, status: "open",
            severity: candidate.severity, priority: candidate.priority,
            evidence_quality: candidate.evidence_quality,
            latest_comparison: comparison,
            first_seen_at: comparison.compared_at, last_seen_at: comparison.compared_at
          )
          finding.save!
          finding.drift_finding_events.create!(
            drift_comparison: comparison, action: "detected", to_status: "open"
          )
        else
          finding.with_lock do
            next if comparison.compared_at < finding.last_seen_at

            finding.update!(
              latest_comparison: comparison,
              last_seen_at: comparison.compared_at,
              evidence_quality: candidate.evidence_quality
            )
            finding.drift_finding_events.create!(
              drift_comparison: comparison, action: "observed"
            )
          end
        end
      end
    end
  end
end
