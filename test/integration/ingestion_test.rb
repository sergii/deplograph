require "test_helper"

class IngestionTest < ActionDispatch::IntegrationTest
  setup do
    @organization = create_test_organization
    @api_token = issue_test_token(organization: @organization)
    @github_token = issue_test_token(organization: @organization, provider: "github_actions")
  end

  test "rejects unauthenticated ingestion" do
    post "/api/v1/inventories", params: "{}", headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :unauthorized
  end

  test "imports inventory idempotently" do
    sbom = JSON.parse(File.read(Rails.root.join("examples/sample_cyclonedx.json")))
    body = { repository: "acme/demo", artifact_identifier: "git:abc",
             format: "cyclonedx", sbom: sbom }
    2.times do
      post "/api/v1/inventories", params: JSON.generate(body), headers: auth_headers
      assert_response :created
      assert_equal 3, response.parsed_body.fetch("component_count")
    end
    assert_equal 1, InventorySnapshot.count
  end

  test "records CI report without falsely claiming runtime observation" do
    body = JSON.parse(File.read(Rails.root.join("examples/sample_deployment.json")))
    2.times do
      post "/api/v1/deployments", params: JSON.generate(body), headers: bearer_headers(@github_token)
      assert_response :created
      assert_equal "reported", response.parsed_body.fetch("evidence")
    end
    assert_equal 1, Deployment.count
    assert_equal "production", Deployment.last.environment.kind
  end

  test "tracks preview creation and destruction" do
    body = JSON.parse(File.read(Rails.root.join("examples/sample_environment_created.json")))
    post "/api/v1/environment_events", params: JSON.generate(body), headers: auth_headers
    assert_response :created
    assert_equal "active", Environment.last.state
    body["event"] = "destroyed"
    post "/api/v1/environment_events", params: JSON.generate(body), headers: auth_headers
    assert_response :created
    assert_equal "destroyed", Environment.last.reload.state
  end

  private

  def auth_headers
    bearer_headers(@api_token)
  end
end
