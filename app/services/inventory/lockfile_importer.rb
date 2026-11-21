require "digest"

module Inventory
  class LockfileImporter
    def call(application:, content:, source: "lockfile")
      document = GemfileLock.new.call(content)
      digest = Digest::SHA256.hexdigest(content)
      Importer.new.call(
        application: application,
        artifact_identifier: "lockfile:sha256:#{digest}",
        kind: "source",
        document: document,
        format: "cyclonedx",
        source: source,
        coverage_status: "partial",
        manifest_type: "Gemfile.lock"
      )
    end
  end
end
