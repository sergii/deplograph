module Vulnerabilities
  class MatchSnapshotJob < ApplicationJob
    queue_as :default

    def perform(snapshot_id, trigger: "manual")
      snapshot = InventorySnapshot.find(snapshot_id)
      scan = nil

      # Claim one scan at a time per snapshot to prevent duplicate queue entries
      # from replacing one another's results.
      snapshot.with_lock do
        return if snapshot.match_status == "running"

        scan = snapshot.vulnerability_scan_runs.create!(
          provider: "osv", trigger: trigger, status: "running", started_at: Time.current
        )
        snapshot.update!(match_status: "running", match_error: nil)
      end

      occurrences = snapshot.component_occurrences.includes(:component).to_a
      versioned = occurrences.select { |occ| occ.component.purl.match?(/@[^?#]+/) }
      matches = OsvClient.new.query_batch(versioned.map { |occ| occ.component.purl })

      InventorySnapshot.transaction do
        snapshot.lock!
        # Keep the complete previous result if an earlier or newer scan
        # finished while this external request was in flight.
        snapshot.vulnerability_matches.where(source: "osv").delete_all

        versioned.each do |occurrence|
          Array(matches[occurrence.component.purl]).uniq { |row| row["id"] }.each do |entry|
            next if entry["id"].blank?

            vulnerability = Vulnerability.find_or_create_by!(identifier: entry.fetch("id"))
            snapshot.vulnerability_matches.create!(
              component_occurrence: occurrence, vulnerability: vulnerability, source: "osv"
            )
          end
        end
        snapshot.update!(match_status: "completed", match_completed_at: Time.current, match_error: nil)
        scan.update!(status: "completed", completed_at: Time.current,
          match_count: snapshot.vulnerability_matches.where(source: "osv").count)
      end
    rescue StandardError => error
      if scan&.persisted?
        scan.update!(status: "failed", completed_at: Time.current, error_class: error.class.name)
        snapshot.update!(match_status: "failed", match_error: error.class.name)
      end
      raise
    end
  end
end
