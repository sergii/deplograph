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

            previous_status = finding.status
            reopened = previous_status == "resolved" && finding.resolved_at.present? &&
              comparison.compared_at > finding.resolved_at
            attrs = {
              latest_comparison: comparison,
              last_seen_at: comparison.compared_at,
              evidence_quality: candidate.evidence_quality
            }
            attrs.merge!(status: "open", resolved_at: nil) if reopened
            finding.update!(attrs)
            if reopened
              finding.drift_finding_events.create!(
                drift_comparison: comparison, action: "reopened",
                from_status: "resolved", to_status: "open",
                note: "The same issue reappeared in later comparison evidence"
              )
            else
              finding.drift_finding_events.create!(
                drift_comparison: comparison, action: "observed"
              )
            end
          end
        end
      end
    end
  end
end
