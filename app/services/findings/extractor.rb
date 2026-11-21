require "digest"

module Findings
  class Extractor
    MAX_ITEMS = 200

    Candidate = Data.define(:category, :subject, :title, :priority, :severity, :evidence_quality)

    def call(comparison)
      result = comparison.result
      dimensions = result.fetch("dimensions", {})
      return [] unless dimensions.is_a?(Hash)

      rows = []
      if comparison.mode == "configuration_fingerprints"
        dimension = dimensions.fetch("environment_value_fingerprints", {})
        Array(dimension["comparisons"]).each do |item|
          next unless item.is_a?(Hash)

          if item["evaluation"] == "violation"
            rows << candidate("policy_violation", item["name"],
              "Policy violation: #{item["name"]}", "p2", "medium", quality(comparison, dimension))
          elsif item["evaluation"] == "unknown"
            rows << candidate("fingerprint_gap", item["name"],
              "Missing value evidence: #{item["name"]}", "p3", "unknown", "unknown")
          end
        end
        if dimension["status"] == "unknown" && rows.empty?
          rows << candidate("fingerprint_gap", "missing-comparable-fingerprints",
            "No comparable HMAC fingerprints", "p3", "unknown", "unknown")
        end
      elsif comparison.mode == "configuration_names"
        dimension = dimensions.fetch("environment_variables", {})
        %w[only_in_baseline only_in_target].each do |direction|
          Array(dimension[direction]).each do |name|
            rows << candidate("env_key_drift", "#{direction}:#{name}",
              "ENV key #{name} seen #{direction == "only_in_target" ? "only in target" : "only in baseline"}",
              "p2", "unknown", quality(comparison, dimension))
          end
        end
        if dimension["status"] == "unknown" && rows.empty?
          rows << candidate("env_key_evidence_gap", "no-comparable-snapshots",
            "ENV snapshots are not comparable", "p3", "unknown", "unknown")
        end
      else
        %w[release artifact dependencies security workloads].each do |dimension_name|
          dimension = dimensions[dimension_name]
          next unless dimension.is_a?(Hash)

          if dimension_name == "security" && dimension["status"] == "different"
            %w[only_in_baseline only_in_target].each do |direction|
              Array(dimension[direction]).each do |advisory|
                rows << candidate("security_advisory", "#{direction}:#{advisory}",
                  "Advisory #{advisory} seen #{direction.humanize.downcase.tr("_", " ")}",
                  "p1", "unknown", quality(comparison, dimension))
              end
            end
          elsif dimension_name == "dependencies" && dimension["status"] == "different"
            Array(dimension["version_changed"]).each do |change|
              name = change.is_a?(Hash) ? change["package"] : nil
              next unless name.is_a?(String)
              rows << candidate("dependency_version", name,
                "Dependency version differs: #{name}", "p2", "medium", quality(comparison, dimension))
            end
            %w[added removed].each do |direction|
              Array(dimension[direction]).each do |change|
                name = change.is_a?(Hash) ? change["package"] : nil
                next unless name.is_a?(String)
                rows << candidate("dependency_#{direction}", name,
                  "Dependency #{direction}: #{name}", "p2", "medium", quality(comparison, dimension))
              end
            end
          elsif dimension["status"] == "different"
            rows << candidate("#{dimension_name}_drift", dimension_name,
              "#{dimension_name.humanize} differs between environments",
              "p2", "medium", quality(comparison, dimension))
          end

          if %w[unknown stale].include?(dimension["status"])
            rows << candidate("#{dimension_name}_evidence_gap", dimension_name,
              "#{dimension_name.humanize} evidence is #{dimension["status"]}",
              "p3", "unknown", dimension["status"])
          end
        end
      end

      rows.compact.uniq { |item| [item.category, item.subject] }.take(MAX_ITEMS).freeze
    end

    private

    def candidate(category, subject, title, priority, severity, evidence_quality)
      return unless subject.is_a?(String) && subject.present? && subject.length <= 200

      Candidate.new(category: category, subject: subject,
        title: title.truncate(250), priority: priority, severity: severity,
        evidence_quality: evidence_quality)
    end

    def quality(comparison, dimension)
      return "stale" if dimension["status"] == "stale"
      return "unknown" if dimension["status"] == "unknown"

      if comparison.mode == "observed" || dimension["confidence"] == "partial" ||
         dimension["inventory_coverage"] == "partial"
        "partial"
      else
        "reported_only"
      end
    end
  end
end
