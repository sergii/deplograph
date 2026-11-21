module Drift
  class Comparator
    MAX_RUNTIME_AGE = 1.hour
    MAX_ADVISORY_AGE = 24.hours

    def call(application:, baseline_name:, target_name:, mode: "reported")
      raise ArgumentError, "Unknown comparison mode" unless %w[reported observed].include?(mode)
      raise ArgumentError, "Environments must differ" if baseline_name == target_name

      baseline = application.environments.find_by!(name: baseline_name)
      target = application.environments.find_by!(name: target_name)

      before = state_for(baseline, mode)
      after = state_for(target, mode)
      dimensions = {
        "release" => release_diff(before, after),
        "artifact" => artifact_diff(before, after),
        "dependencies" => dependency_diff(before, after),
        "security" => security_diff(before, after)
      }
      dimensions["workloads"] = workload_diff(before, after) if mode == "observed"

      unknown = dimensions.filter_map do |dimension, values|
        dimension if %w[unknown stale partial].include?(values.fetch("status")) ||
          values["inventory_coverage"] == "partial"
      end
      known_differences = dimensions.filter_map do |dimension, values|
        dimension if values.fetch("status") == "different"
      end

      missing = before[:entries].empty? || after[:entries].empty?
      stale = mode == "observed" && (before[:stale] || after[:stale])
      status = if missing
        "unknown"
      elsif known_differences.any?
        "different"
      elsif stale
        "stale"
      elsif unknown.any? || mode == "observed" ||
            before[:environment].state != "active" || after[:environment].state != "active"
        "partial"
      else
        "same"
      end

      result = {
        "status" => status,
        "mode" => mode,
        "verified_runtime" => false,
        "confidence" => (unknown.any? || mode == "observed") ? "partial" : "reported_only",
        "known_differences" => known_differences,
        "incomplete_dimensions" => unknown,
        "baseline" => evidence(before),
        "target" => evidence(after),
        "dimensions" => dimensions
      }

      DriftComparison.create!(
        organization: application.organization, application: application,
        baseline_environment: baseline, target_environment: target,
        mode: mode, status: status, result: result, compared_at: Time.current
      )
    end

    private

    def state_for(environment, mode)
      entries = if mode == "reported"
        deployment = environment.deployments.includes(:artifact, :release)
          .order(deployed_at: :desc, id: :desc).first
        if deployment
          [{ workload: "reported", artifact: deployment.artifact,
             identifier: deployment.artifact.image_digest.presence ||
               deployment.artifact.identifier,
             snapshot: latest_snapshot(deployment.artifact),
             release: deployment.release&.name,
             event_id: deployment.external_id, at: deployment.deployed_at }]
        else
          []
        end
      else
        environment.deployment_observations
          .order(observed_at: :desc, id: :desc).to_a.uniq(&:workload).map do |observation|
          { workload: observation.workload, artifact: observation.artifact,
            identifier: observation.image_digest,
            snapshot: latest_snapshot(observation.artifact),
            release: nil, event_id: observation.event_id, at: observation.observed_at }
        end
      end

      { environment: environment, mode: mode, entries: entries,
        stale: mode == "observed" &&
          entries.any? { |entry| entry[:at] < Time.current - MAX_RUNTIME_AGE } }
    end

    def latest_snapshot(artifact)
      artifact&.inventory_snapshots&.order(created_at: :desc, id: :desc)&.first
    end

    def evidence(state)
      {
        "environment" => state.fetch(:environment).name,
        "lifecycle_state" => state.fetch(:environment).state,
        "evidence_level" => state.fetch(:mode) == "observed" ?
          "partial_runtime_observation" : "deployment_report",
        "stale" => !!state.fetch(:stale),
        "workloads" => state.fetch(:entries).map do |entry|
          snapshot = entry[:snapshot]
          {
            "name" => entry.fetch(:workload),
            "artifact_identifier" => entry.fetch(:identifier),
            "event_id" => entry[:event_id],
            "recorded_at" => entry[:at],
            "inventory_snapshot_id" => snapshot&.id,
            "inventory_sha256" => snapshot&.sha256,
            "inventory_coverage" => snapshot&.coverage_status || "missing",
            "scan_status" => snapshot&.match_status || "not_scanned",
            "scan_completed_at" => snapshot&.match_completed_at
          }
        end
      }
    end

    def release_diff(before, after)
      return unknown_dimension("No release mapping for runtime observation") if
        before[:mode] == "observed"
      baseline = before[:entries].map { |entry| entry[:release] }.compact.sort
      target = after[:entries].map { |entry| entry[:release] }.compact.sort
      return unknown_dimension("Release mapping missing") if baseline.empty? || target.empty?

      { "status" => baseline == target ? "same" : "different",
        "baseline" => baseline, "target" => target }
    end

    def artifact_diff(before, after)
      baseline = before[:entries].map { |entry| entry[:identifier] }.compact.sort
      target = after[:entries].map { |entry| entry[:identifier] }.compact.sort
      return unknown_dimension("Artifact identity missing") if baseline.empty? || target.empty?

      { "status" => baseline == target ? "same" : "different",
        "baseline" => baseline, "target" => target }
    end

    def dependency_diff(before, after)
      before_packages = packages(before)
      after_packages = packages(after)
      return unknown_dimension("One or more artifacts have no inventory") unless
        before_packages && after_packages

      added = after_packages.keys.-(before_packages.keys).sort.map do |name|
        { "package" => name, "versions" => after_packages.fetch(name) }
      end
      removed = before_packages.keys.-(after_packages.keys).sort.map do |name|
        { "package" => name, "versions" => before_packages.fetch(name) }
      end
      changed = (before_packages.keys & after_packages.keys).sort.filter_map do |name|
        old_versions = before_packages.fetch(name)
        new_versions = after_packages.fetch(name)
        next if old_versions == new_versions

        { "package" => name, "baseline_versions" => old_versions,
          "target_versions" => new_versions }
      end

      different = added.any? || removed.any? || changed.any?
      complete = both_complete?(before, after)
      { "status" => different ? "different" : (complete ? "same" : "partial"),
        "known_relation" => different ? "different" : "same",
        "inventory_coverage" => complete ? "complete" : "partial",
        "added" => added, "removed" => removed,
        "version_changed" => changed,
        "baseline_package_count" => before_packages.size,
        "target_package_count" => after_packages.size }
    end

    def packages(state)
      entries = state.fetch(:entries)
      return nil if entries.empty? || entries.any? { |entry| entry[:snapshot].nil? }

      components = entries.flat_map do |entry|
        entry[:snapshot].component_occurrences.includes(:component).map(&:component)
      end
      components.group_by { |component| "#{component.ecosystem}:#{component.name}" }
        .transform_values { |items| items.map(&:version).compact.uniq.sort }
    end

    def both_complete?(before, after)
      [before, after].all? do |state|
        state[:entries].all? do |entry|
          entry[:snapshot] && entry[:snapshot].coverage_status == "complete"
        end
      end
    end

    def security_diff(before, after)
      snapshots = [before, after].flat_map do |state|
        state[:entries].map { |entry| entry[:snapshot] }
      end
      return unknown_dimension("Inventory or advisory scan missing") if
        snapshots.empty? || snapshots.any?(&:nil?) ||
        snapshots.any? { |snapshot| snapshot.match_status != "completed" }

      if snapshots.any? { |snapshot| snapshot.match_completed_at.nil? ||
                          snapshot.match_completed_at < Time.current - MAX_ADVISORY_AGE }
        return { "status" => "stale", "reason" => "Advisory scan older than 24 hours" }
      end

      old_ids = vulnerability_ids(before)
      new_ids = vulnerability_ids(after)
      added = (new_ids - old_ids).sort
      removed = (old_ids - new_ids).sort
      complete = both_complete?(before, after)
      different = added.any? || removed.any?
      { "status" => different ? "different" : (complete ? "same" : "partial"),
        "known_relation" => different ? "different" : "same",
        "inventory_coverage" => complete ? "complete" : "partial",
        "only_in_target" => added,
        "only_in_baseline" => removed,
        "shared" => (old_ids & new_ids).sort,
        "baseline_known_match_count" => old_ids.size,
        "target_known_match_count" => new_ids.size }
    end

    def vulnerability_ids(state)
      state[:entries].flat_map do |entry|
        entry[:snapshot].vulnerability_matches.includes(:vulnerability)
          .map { |match| match.vulnerability.identifier }
      end.uniq
    end

    def workload_diff(before, after)
      old_names = before[:entries].map { |entry| entry[:workload] }.sort
      new_names = after[:entries].map { |entry| entry[:workload] }.sort
      # An unobserved workload is not proof that it is absent.
      { "status" => "partial",
        "known_relation" => old_names == new_names ? "same" : "different",
        "observed_only_in_target" => (new_names - old_names),
        "observed_only_in_baseline" => (old_names - new_names) }
    end

    def unknown_dimension(reason)
      { "status" => "unknown", "reason" => reason }
    end
  end
end
