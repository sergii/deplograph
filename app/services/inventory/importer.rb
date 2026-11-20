require "digest"
require "json"

module Inventory
  class Importer
    class InvalidDocument < StandardError; end

    MAX_COMPONENTS = 50_000

    def call(application:, artifact_identifier:, document:, format:, kind: "source",
             source: "api", image_digest: nil, commit_sha: nil)
      raise InvalidDocument, "SBOM must be a JSON object" unless document.is_a?(Hash)

      components, relationships = extract(document, format)
      raise InvalidDocument, "SBOM exceeds component limit" if components.length > MAX_COMPONENTS

      digest = Digest::SHA256.hexdigest(JSON.generate(document))

      InventorySnapshot.transaction do
        artifact = application.artifacts.find_or_initialize_by(identifier: artifact_identifier)
        artifact.assign_attributes(kind: kind, image_digest: image_digest, commit_sha: commit_sha)
        artifact.save!

        snapshot = artifact.inventory_snapshots.find_or_initialize_by(sha256: digest)
        return snapshot if snapshot.persisted?

        snapshot.assign_attributes(format: format, raw_document: document, source: source)
        snapshot.save!

        references = {}
        components.each do |entry|
          purl = entry["purl"].to_s
          next unless purl.start_with?("pkg:")

          component = Component.find_or_create_by!(purl: purl) do |record|
            record.name = entry["name"].presence || purl.split("/").last.to_s.split("@").first
            record.version = entry["version"]
            record.ecosystem = purl.delete_prefix("pkg:").split("/").first
          end

          occurrence = snapshot.component_occurrences.create!(
            component: component, bom_ref: entry["ref"].presence
          )
          references[entry["ref"]] = occurrence if entry["ref"].present?
        end

        relationships.each do |from_ref, to_ref|
          from = references[from_ref]
          to = references[to_ref]
          next unless from && to && from.id != to.id

          snapshot.dependency_edges.find_or_create_by!(
            from_occurrence: from, to_occurrence: to
          )
        end

        snapshot
      end
    end

    private

    def extract(document, format)
      case format
      when "cyclonedx"
        raise InvalidDocument, "Not a CycloneDX document" unless document["bomFormat"] == "CycloneDX"
        entries = Array(document["components"]).map do |item|
          next unless item.is_a?(Hash)
          { "ref" => item["bom-ref"], "purl" => item["purl"],
            "name" => item["name"], "version" => item["version"] }
        end.compact
        edges = Array(document["dependencies"]).flat_map do |item|
          next [] unless item.is_a?(Hash)
          Array(item["dependsOn"]).map { |dep| [item["ref"], dep] }
        end
        [entries, edges]
      when "spdx"
        raise InvalidDocument, "Only SPDX 2.x documents supported" unless document["spdxVersion"].to_s.start_with?("SPDX-2.")
        entries = Array(document["packages"]).filter_map do |item|
          next unless item.is_a?(Hash)
          purl = Array(item["externalRefs"]).find do |ref|
            ref["referenceType"] == "purl"
          end&.dig("referenceLocator")
          { "ref" => item["SPDXID"], "purl" => purl,
            "name" => item["name"], "version" => item["versionInfo"] }
        end
        edges = Array(document["relationships"]).filter_map do |item|
          next unless item.is_a?(Hash) && item["relationshipType"] == "DEPENDS_ON"
          [item["spdxElementId"], item["relatedSpdxElement"]]
        end
        [entries, edges]
      else
        raise InvalidDocument, "Supported formats: cyclonedx, spdx"
      end
    end
  end
end
