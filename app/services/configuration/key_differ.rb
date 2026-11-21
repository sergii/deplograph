module Configuration
  class KeyDiffer
    MAX_PROCESS_AGE = 1.hour
    MAX_DECLARED_AGE = 24.hours

    def call(application:, baseline_name:, target_name:, workload:, scope:)
      raise ArgumentError, "Environments must differ" if baseline_name == target_name
      raise ArgumentError, "Invalid scope" unless ConfigurationSnapshot::SCOPES.include?(scope)
      raise ArgumentError, "Invalid workload" unless
        workload.is_a?(String) && workload.match?(SnapshotRecorder::WORKLOAD_PATTERN)

      baseline = application.environments.find_by!(name: baseline_name)
      target = application.environments.find_by!(name: target_name)
      left = latest(baseline, workload, scope)
      right = latest(target, workload, scope)

      return unknown("A comparable snapshot is missing", left, right, scope, workload) unless left && right
      return unknown("Snapshots use different collector sources", left, right, scope, workload) if
        left.source != right.source

      baseline_keys = left.configuration_entries.pluck(:name).to_set
      target_keys = right.configuration_entries.pluck(:name).to_set
      only_left = (baseline_keys - target_keys).to_a.sort
      only_right = (target_keys - baseline_keys).to_a.sort
      complete = [left, right].all? { |s| s.completeness == "complete" }
      age_limit = scope == "process" ? MAX_PROCESS_AGE : MAX_DECLARED_AGE
      stale = [left, right].any? { |s| s.collected_at < Time.current - age_limit }
      different = only_left.any? || only_right.any?

      status = if stale
        "stale"
      elsif different
        "different"
      elsif complete
        "same"
      else
        "partial"
      end

      {
        status: status, scope: scope, workload: workload,
        baseline: evidence(left), target: evidence(right),
        baseline_count: baseline_keys.size, target_count: target_keys.size,
        common_count: (baseline_keys & target_keys).size,
        only_in_baseline: only_left, only_in_target: only_right,
        confidence: complete ? "complete" : "partial",
        absence_confirmed: complete,
        values_compared: false
      }
    end

    private

    def latest(environment, workload, scope)
      environment.configuration_snapshots
        .where(workload: workload, scope: scope)
        .order(collected_at: :desc, id: :desc).first
    end

    def evidence(snapshot)
      return nil unless snapshot
      {
        snapshot_id: snapshot.id, source: snapshot.source,
        completeness: snapshot.completeness, collected_at: snapshot.collected_at,
        keys_sha256: snapshot.keys_sha256
      }
    end

    def unknown(reason, left, right, scope, workload)
      {
        status: "unknown", reason: reason, scope: scope, workload: workload,
        baseline: evidence(left), target: evidence(right),
        values_compared: false, absence_confirmed: false
      }
    end
  end
end
