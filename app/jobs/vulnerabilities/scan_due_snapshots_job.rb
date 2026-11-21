module Vulnerabilities
  class ScanDueSnapshotsJob < ApplicationJob
    queue_as :default

    DEFAULT_INTERVAL = 24.hours
    MAX_BATCH = 200

    def perform(interval_seconds: DEFAULT_INTERVAL.to_i, limit: MAX_BATCH)
      return unless ENV["OSV_ENABLED"] == "true"

      cutoff = Time.current - Integer(interval_seconds)
      batch_size = Integer(limit).clamp(1, MAX_BATCH)
      InventorySnapshot.where("match_completed_at IS NULL OR match_completed_at < ?", cutoff)
        .where.not(match_status: "running")
        .order(Arel.sql("COALESCE(match_completed_at, created_at) ASC"), :id)
        .limit(batch_size).pluck(:id).each do |snapshot_id|
          MatchSnapshotJob.perform_later(snapshot_id, trigger: "scheduled")
        end
    end
  end
end
