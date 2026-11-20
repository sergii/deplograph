require "test_helper"
require "minitest/mock"

module Vulnerabilities
  class MatchSnapshotJobTest < ActiveSupport::TestCase
    setup do
      application = Application.create!(name: "Demo", repository_full_name: "acme/job-demo")
      @snapshot = Inventory::Importer.new.call(
        application: application, artifact_identifier: "git:demo",
        format: "cyclonedx",
        document: JSON.parse(File.read(Rails.root.join("examples/sample_cyclonedx.json")))
      )
    end

    test "saves affected version matches" do
      fake = Object.new
      fake.define_singleton_method(:query_batch) do |purls|
        purls.to_h { |p| [p, p.include?("rack") ? [{ "id" => "GHSA-demo" }] : []] }
      end
      OsvClient.stub(:new, fake) { MatchSnapshotJob.perform_now(@snapshot.id) }
      assert_equal "completed", @snapshot.reload.match_status
      assert_equal 1, @snapshot.vulnerability_matches.count
      assert_equal "GHSA-demo", Vulnerability.last.identifier
    end

    test "failed matching is not represented as safe" do
      fake = Object.new
      fake.define_singleton_method(:query_batch) { |_purls| raise OsvClient::QueryError, "unavailable" }
      assert_raises(OsvClient::QueryError) do
        OsvClient.stub(:new, fake) { MatchSnapshotJob.perform_now(@snapshot.id) }
      end
      assert_equal "failed", @snapshot.reload.match_status
    end
  end
end
