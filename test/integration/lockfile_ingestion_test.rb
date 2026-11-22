require "test_helper"

class LockfileIngestionTest < ActionDispatch::IntegrationTest
  setup do
    @organization = create_test_organization
    @token = issue_test_token(
      organization: @organization,
      provider: "api", permissions: %w[read report],
      repository_scopes: ["acme/ruby-demo"]
    )
    @lockfile = File.read(Rails.root.join("examples/scenarios/rails-lockfile/Gemfile.lock"))
  end

  test "a scoped reporter can import and reimport the same Gemfile.lock" do
    body = { repository: "acme/ruby-demo", lockfile: @lockfile }
    2.times do
      post "/api/v1/inventories/lockfile",
        params: JSON.generate(body), headers: bearer_headers(@token)
      assert_response :created
      assert_equal 3, response.parsed_body.fetch("component_count")
      assert_equal "partial", response.parsed_body.fetch("coverage_status")
    end
    assert_equal 1, InventorySnapshot.count
  end

  test "a token for another repository cannot import lockfiles" do
    post "/api/v1/inventories/lockfile",
      params: JSON.generate(repository: "acme/other", lockfile: @lockfile),
      headers: bearer_headers(@token)
    assert_response :forbidden
    assert_equal 0, Application.count
  end

  test "an invalid lockfile is rejected without creating inventory" do
    post "/api/v1/inventories/lockfile",
      params: JSON.generate(repository: "acme/ruby-demo", lockfile: "not a lockfile"),
      headers: bearer_headers(@token)
    assert_response :unprocessable_entity
    assert_equal 0, InventorySnapshot.count
  end
end
