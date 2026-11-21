module Vulnerabilities
  class MatchSnapshotJob < ApplicationJob
    queue_as :default

    def perform(snapshot_id)
      snapshot = InventorySnapshot.find(snapshot_id)
      snapshot.update!(match_status: "running", match_error: nil)
      occurrences = snapshot.component_occurrences.includes(:component).to_a
      versioned = occurrences.select { |occ| occ.component.purl.match?(/@[^?#]+/) }
      matches = OsvClient.new.query_batch(versioned.map { |occ| occ.component.purl })

      InventorySnapshot.transaction do
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
      end
    rescue StandardError => error
      snapshot&.update!(match_status: "failed", match_error: error.class.name)
      raise
    end
  end
end
