require "test_helper"

module Vulnerabilities
  class MatchSnapshotJobTest < ActiveSupport::TestCase
    setup do
      application = Application.create!(organization: create_test_organization, name: "Demo", repository_full_name: "acme/job-demo")
      @snapshot = Inventory::Importer.new.call(
        application: application, artifact_identifier: "git:demo",
        format: "cyclonedx",
        document: JSON.parse(File.read(Rails.root.join("examples/sample_cyclonedx.json")))
      )
    end

    test "saves affected version matches" do
      stub_request(:post, OsvClient::API_URL).to_return do |request|
        queries = JSON.parse(request.body).fetch("queries")
        results = queries.map do |query|
          package = query.fetch("package").fetch("purl")
          { vulns: package.include?("rack") ? [{ id: "GHSA-demo" }] : [] }
        end
        { status: 200, body: JSON.generate(results: results) }
      end
      MatchSnapshotJob.perform_now(@snapshot.id)
      assert_equal "completed", @snapshot.reload.match_status
      assert_equal 1, @snapshot.vulnerability_matches.count
      assert_equal "GHSA-demo", Vulnerability.last.identifier
    end

    test "rescanning replaces only OSV matches and preserves findings from other sources" do
      advisory = Vulnerability.create!(identifier: "GHSA-simulation")
      @snapshot.vulnerability_matches.create!(
        component_occurrence: @snapshot.component_occurrences.first,
        vulnerability: advisory, source: "simulation"
      )
      call_count = 0
      stub_request(:post, OsvClient::API_URL).to_return do |request|
        call_count += 1
        queries = JSON.parse(request.body).fetch("queries")
        vulns = call_count == 1 ? [{ id: "GHSA-first-run" }] : []
        results = queries.map do |query|
          purl = query.fetch("package").fetch("purl")
          { vulns: purl.include?("rack") ? vulns : [] }
        end
        { status: 200, body: JSON.generate(results: results) }
      end

      MatchSnapshotJob.perform_now(@snapshot.id)
      assert_equal 1, @snapshot.vulnerability_matches.where(source: "osv").count
      assert_equal 1, @snapshot.vulnerability_matches.where(source: "simulation").count

      MatchSnapshotJob.perform_now(@snapshot.id)
      assert_equal 0, @snapshot.vulnerability_matches.where(source: "osv").count
      assert_equal 1, @snapshot.vulnerability_matches.where(source: "simulation").count
      assert_equal "GHSA-simulation", @snapshot.vulnerability_matches.first.vulnerability.identifier
    end

    test "failed matching is not represented as safe" do
      stub_request(:post, OsvClient::API_URL).to_return(status: 503)
      assert_raises(OsvClient::QueryError) do
        MatchSnapshotJob.perform_now(@snapshot.id)
      end
      assert_equal "failed", @snapshot.reload.match_status
    end
  end
end
