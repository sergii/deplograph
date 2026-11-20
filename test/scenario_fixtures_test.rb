require "test_helper"

class ScenarioFixturesTest < ActiveSupport::TestCase
  test "cross-provider fixtures share release, environment, deployment and artifact identity" do
    fixtures = %w[github_actions_report kamal_report kubernetes_observation].map do |name|
      JSON.parse(File.read(Rails.root.join("examples/scenarios/#{name}.json")))
    end
    assert_equal %w[github_actions kamal kubernetes], fixtures.map { |event| event.fetch("source") }
    assert_equal 1, fixtures.map { |event| event.fetch("deployment_id") }.uniq.length
    assert_equal 1, fixtures.map { |event| event.fetch("image_digest") }.uniq.length
    assert_equal 1, fixtures.map { |event| event.fetch("repository") }.uniq.length
    assert_equal "artifact.observed", fixtures.last.fetch("event_type")
    assert_equal %w[deployment.reported deployment.reported], fixtures.first(2).map { |event| event.fetch("event_type") }
  end

  test "GitHub Actions deployment reporter targets the evidence ingestion API" do
    workflow = File.read(Rails.root.join(".github/workflows/deployment-report.yml"))
    assert_includes workflow, "/api/v1/integration_events"
    assert_includes workflow, "deployment.reported"
    assert_includes workflow, "SHARED_DEPLOYMENT_ID"
  end
end
