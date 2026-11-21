module Configuration
  class FingerprintDiffer
    def call(application:, baseline_name:, target_name:, workload:, scope:)
      names = KeyDiffer.new.call(
        application: application, baseline_name: baseline_name,
        target_name: target_name, workload: workload, scope: scope
      )
      left = names.dig(:baseline, :snapshot_id) &&
        ConfigurationSnapshot.find(names.dig(:baseline, :snapshot_id))
      right = names.dig(:target, :snapshot_id) &&
        ConfigurationSnapshot.find(names.dig(:target, :snapshot_id))

      return unknown_result("Names-only snapshots are missing or not comparable", names) unless
        left && right && left.source == right.source

      a = left.configuration_fingerprint_batches.order(created_at: :desc, id: :desc).first
      b = right.configuration_fingerprint_batches.order(created_at: :desc, id: :desc).first
      return unknown_result("Fingerprints are missing", names) unless a && b
      return unknown_result("HMAC key IDs or algorithms differ", names) unless
        a.key_id == b.key_id && a.algorithm == b.algorithm

      left_hmacs = a.fingerprints_by_name
      right_hmacs = b.fingerprints_by_name
      left_keys = left.configuration_entries.pluck(:name)
      right_keys = right.configuration_entries.pluck(:name)
      complete = left.completeness == "complete" && right.completeness == "complete" &&
        left_hmacs.size == left_keys.size && right_hmacs.size == right_keys.size
      policies = application.configuration_policies
        .where(baseline_environment: left.environment,
          target_environment: right.environment, workload: workload, scope: scope)
        .index_by(&:name)
      union = (left_keys | right_keys | policies.keys).sort

      violations = []
      unresolved = []
      comparisons = union.map do |name|
        rule = policies[name]&.rule || "must_match"
        presence = if left_keys.include?(name) && right_keys.include?(name)
          "both"
        elsif left_keys.include?(name)
          "baseline_only"
        elsif right_keys.include?(name)
          "target_only"
        else
          "absent_both"
        end
        relation = if presence != "both"
          "missing"
        elsif !left_hmacs.key?(name) || !right_hmacs.key?(name)
          "unknown"
        elsif left_hmacs.fetch(name) == right_hmacs.fetch(name)
          "equal"
        else
          "different"
        end

        evaluation = if rule == "ignore"
          "ignored"
        elsif relation == "missing" && !complete
          "unknown"
        elsif %w[unknown missing].include?(relation)
          relation == "missing" ? "violation" : "unknown"
        elsif rule == "must_match"
          relation == "equal" ? "compliant" : "violation"
        elsif rule == "must_differ"
          relation == "different" ? "compliant" : "violation"
        else
          "compliant"
        end

        violations << name if evaluation == "violation"
        unresolved << name if evaluation == "unknown"
        {
          "name" => name, "presence" => presence, "policy" => rule,
          "value_relation" => relation, "evaluation" => evaluation
        }
      end

      freshness = names.fetch(:status)
      status = if freshness == "stale"
        "stale"
      elsif violations.any?
        "different"
      elsif !complete || unresolved.any? || freshness == "partial"
        "partial"
      else
        "same"
      end

      {
        status: status, status_semantics: "policy_compliance",
        policy_compliant: violations.empty? && unresolved.empty? && complete && status != "stale",
        known_value_differences: comparisons.select { |item|
          item["value_relation"] == "different"
        }.map { |item| item["name"] },
        values_compared: true, plaintext_collected: false,
        algorithm: a.algorithm, key_id: a.key_id,
        baseline: { snapshot_id: left.id, fingerprint_batch_id: a.id },
        target: { snapshot_id: right.id, fingerprint_batch_id: b.id },
        key_names: names.slice(:baseline_count, :target_count, :common_count,
          :only_in_baseline, :only_in_target),
        comparisons: comparisons,
        policy_violations: violations, unresolved_keys: unresolved,
        confidence: complete ? "complete" : "partial",
        reason: status == "stale" ? "Configuration evidence is stale" : nil
      }
    end

    private

    def unknown_result(reason, names)
      {
        status: "unknown", reason: reason, status_semantics: "policy_compliance",
        policy_compliant: false, known_value_differences: [],
        values_compared: false, plaintext_collected: false,
        baseline: names[:baseline], target: names[:target],
        key_names: names.slice(:baseline_count, :target_count, :common_count,
          :only_in_baseline, :only_in_target),
        policy_violations: [], unresolved_keys: [], comparisons: [],
        confidence: "unknown"
      }
    end
  end
end
