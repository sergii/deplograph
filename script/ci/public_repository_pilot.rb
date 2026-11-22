# frozen_string_literal: true

# Live, read-only provider smoke. Never deploy this script as a production job.
# The repository is deliberately fixed to a public Rails application.
require "json"
require "net/http"
require "securerandom"
require "uri"

repository = "discourse/discourse"
url = URI("https://raw.githubusercontent.com/discourse/discourse/main/Gemfile.lock")
response = Net::HTTP.start(url.host, url.port, use_ssl: true,
  open_timeout: 8, read_timeout: 30) { |http| http.get(url.request_uri) }
raise "GitHub returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
raise "Public lockfile was unexpectedly large" if response.body.bytesize > 1_000_000

organization = Organization.create!(
  name: "Isolated public pilot", slug: "pilot-#{SecureRandom.hex(6)}"
)
_credential, token = IntegrationCredential.issue!(
  organization: organization,
  name: "One-off pilot read/report",
  provider: "api", permissions: %w[read report],
  repository_scopes: [repository]
)

# Use the actual scoped HTTP ingestion API rather than bypassing authorization.
client = ActionDispatch::Integration::Session.new(Rails.application)
client.post("/api/v1/inventories/lockfile",
  params: JSON.generate(repository: repository, lockfile: response.body),
  headers: {
    "CONTENT_TYPE" => "application/json",
    "Authorization" => "Bearer #{token}"
  })
raise "Lockfile API returned HTTP #{client.response.status}" unless client.response.status == 201

receipt = JSON.parse(client.response.body)
snapshot = InventorySnapshot.find(receipt.fetch("inventory_snapshot_id"))
raise "Repository inventory was empty" unless snapshot.component_occurrences.count > 10
raise "Source lockfile must have partial coverage" unless snapshot.coverage_status == "partial"
raise "A source lockfile is not a runtime assertion" unless snapshot.artifact.kind == "source"
raise "Scan must start as not_scanned" unless snapshot.match_status == "not_scanned"

# Query the real OSV API. The CI test suite normally uses WebMock instead.
# Invoke the job's domain operation directly in Rails runner: this smoke
# exercises real matching and persistence, not Active Job instrumentation.
Vulnerabilities::MatchSnapshotJob.new.perform(snapshot.id, trigger: "manual")
snapshot.reload
raise "OSV scan did not complete" unless snapshot.match_status == "completed"
scan = snapshot.vulnerability_scan_runs.order(:id).last
raise "Missing persisted advisory scan history" unless scan&.status == "completed"

puts JSON.generate({
  result: "passed",
  repository: repository,
  inventory_source: "public Gemfile.lock",
  inventory_coverage: snapshot.coverage_status,
  source_components: snapshot.component_occurrences.count,
  advisory_status: snapshot.match_status,
  known_advisory_matches: scan.match_count,
  runtime_verified: false
})
