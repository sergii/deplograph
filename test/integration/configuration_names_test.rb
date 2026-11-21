require "test_helper"
require_relative "../../collectors/lib/deplograph/env_keys_collector"

class ConfigurationNamesTest < ActionDispatch::IntegrationTest
  setup do
    @organization = create_test_organization
    @reporter = issue_test_token(
      organization: @organization, provider: "github_actions",
      permissions: %w[report], repository_scopes: ["acme/payments"]
    )
    @observer = issue_test_token(
      organization: @organization, provider: "docker_agent",
      permissions: %w[observe], repository_scopes: ["acme/payments"]
    )
    @reader = issue_test_token(
      organization: @organization, provider: "api",
      permissions: %w[read], repository_scopes: ["acme/payments"]
    )
  end

  test "compares ENV key counts and names, never values" do
    create_snapshot(environment: "staging", keys: %w[DATABASE_URL REDIS_URL FEATURE_NEW_CHECKOUT])
    create_snapshot(environment: "production", keys: %w[DATABASE_URL REDIS_URL LEGACY_API_KEY PAYMENT_GATEWAY_TOKEN])

    compare_names
    assert_response :created
    id = response.parsed_body.fetch("id")
    result = response.parsed_body.fetch("result")
    assert_equal "different", result.fetch("status")
    assert_equal false, result.fetch("values_compared")
    dimension = result.dig("dimensions", "environment_variables")
    assert_equal 3, dimension.fetch("baseline_count")
    assert_equal 4, dimension.fetch("target_count")
    assert_equal 2, dimension.fetch("common_count")
    assert_equal ["FEATURE_NEW_CHECKOUT"], dimension.fetch("only_in_baseline")
    assert_equal %w[LEGACY_API_KEY PAYMENT_GATEWAY_TOKEN], dimension.fetch("only_in_target")
    assert_equal "complete", dimension.fetch("confidence")
    assert_equal true, dimension.fetch("absence_confirmed")
    assert_equal 1, DriftComparison.where(mode: "configuration_names").count

    get "/api/v1/drift/comparisons/#{id}", headers: bearer_headers(@reader)
    assert_response :success
    assert_equal "different", response.parsed_body.fetch("status")
  end

  test "90 staging keys versus 110 production keys can mean 10 removed and 30 added" do
    shared = (1..80).map { |i| "SHARED_#{i}" }
    staging = shared + (1..10).map { |i| "STAGING_#{i}" }
    production = shared + (1..30).map { |i| "PRODUCTION_#{i}" }
    create_snapshot(environment: "staging", keys: staging)
    create_snapshot(environment: "production", keys: production)
    compare_names

    assert_response :created
    result = response.parsed_body.dig("result", "dimensions", "environment_variables")
    assert_equal 90, result.fetch("baseline_count")
    assert_equal 110, result.fetch("target_count")
    assert_equal 80, result.fetch("common_count")
    assert_equal 10, result.fetch("only_in_baseline").length
    assert_equal 30, result.fetch("only_in_target").length
    assert_equal "different", result.fetch("status")
  end

  test "equal key counts do not imply the same set of keys" do
    create_snapshot(environment: "staging", keys: %w[A B C])
    create_snapshot(environment: "production", keys: %w[A B D])
    compare_names

    assert_response :created
    result = response.parsed_body.dig("result", "dimensions", "environment_variables")
    assert_equal 3, result.fetch("baseline_count")
    assert_equal 3, result.fetch("target_count")
    assert_equal ["C"], result.fetch("only_in_baseline")
    assert_equal ["D"], result.fetch("only_in_target")
    assert_equal "different", result.fetch("status")
  end

  test "ENV snapshot ingestion rejects values and unsupported fields before persistence" do
    body = snapshot_body(environment: "staging", keys: ["DATABASE_URL"])
    body[:values] = { DATABASE_URL: "postgres://password@host/database" }
    post_snapshot(body)
    assert_response :unprocessable_entity
    assert_equal 0, ConfigurationSnapshot.count
    assert_equal 0, ConfigurationEntry.count

    body.delete(:values)
    body[:keys] = ["DATABASE_URL=password"]
    post_snapshot(body)
    assert_response :unprocessable_entity
    assert_equal 0, ConfigurationSnapshot.count
    assert_equal 0, ConfigurationEntry.count

    body[:keys] = ["REDIS_URL", "REDIS_URL"]
    post_snapshot(body)
    assert_response :unprocessable_entity
    assert_equal 0, ConfigurationSnapshot.count
  end

  test "snapshots dedupe by collection id but reject conflicting retries" do
    body = snapshot_body(environment: "staging", keys: %w[DATABASE_URL REDIS_URL])
    2.times do
      post_snapshot(body)
      assert_response :created
    end
    assert_equal 1, ConfigurationSnapshot.count
    assert_equal 2, ConfigurationEntry.count

    body[:keys] = %w[DATABASE_URL OTHER_KEY]
    post_snapshot(body)
    assert_response :conflict
    assert_equal 1, ConfigurationSnapshot.count
    assert_equal %w[DATABASE_URL REDIS_URL],
      ConfigurationSnapshot.last.configuration_entries.pluck(:name).sort
  end

  test "comparing incomplete snapshots never confirms that keys are absent" do
    create_snapshot(environment: "staging",
      keys: %w[DATABASE_URL REDIS_URL], completeness: "partial")
    create_snapshot(environment: "production",
      keys: %w[DATABASE_URL REDIS_URL], completeness: "complete")
    compare_names
    assert_response :created
    dimension = response.parsed_body.dig("result", "dimensions", "environment_variables")
    assert_equal "partial", dimension.fetch("status")
    assert_equal "partial", dimension.fetch("confidence")
    assert_equal false, dimension.fetch("absence_confirmed")
    assert_equal [], dimension.fetch("only_in_target")
  end

  test "different sources or missing snapshots return unknown, not an empty diff" do
    create_snapshot(environment: "staging", source: "github_actions",
      keys: %w[DATABASE_URL])
    @organization.applications.find_by!(repository_full_name: "acme/payments")
      .environments.find_or_create_by!(name: "production") { |env| env.kind = "production" }
    compare_names
    assert_equal "unknown", response.parsed_body.fetch("status")

    create_snapshot(environment: "production", source: "docker_agent",
      scope: "process", keys: %w[DATABASE_URL], token: @observer)
    compare_names
    assert_equal "unknown", response.parsed_body.fetch("status")

    create_snapshot(environment: "production", source: "docker_agent",
      scope: "declared", keys: %w[DATABASE_URL], token: @observer,
      expected_status: :forbidden)
  end

  test "stale configuration evidence is not labeled current" do
    time = 48.hours.ago.utc.iso8601
    create_snapshot(environment: "staging", keys: %w[DATABASE_URL], collected_at: time)
    create_snapshot(environment: "production", keys: %w[DATABASE_URL], collected_at: time)
    compare_names
    assert_response :created
    assert_equal "stale", response.parsed_body.fetch("status")
    assert_equal false, response.parsed_body.dig("result", "verified_runtime")
  end

  test "read permissions are scoped to both environments and tenant" do
    create_snapshot(environment: "staging", keys: %w[DATABASE_URL])
    create_snapshot(environment: "production", keys: %w[REDIS_URL])

    limited = issue_test_token(
      organization: @organization, permissions: %w[read],
      repository_scopes: ["acme/payments"],
      environment_scopes: ["staging"]
    )
    post "/api/v1/configuration/drift", params: JSON.generate(
      repository: "acme/payments", baseline_environment: "staging",
      target_environment: "production", workload: "web", scope: "declared"
    ), headers: bearer_headers(limited)
    assert_response :forbidden

    get "/api/v1/configuration_snapshots",
      params: { repository: "acme/payments", environment: "production" },
      headers: bearer_headers(limited)
    assert_response :forbidden

    get "/api/v1/configuration_snapshots",
      params: { repository: "acme/payments", environment: "staging" },
      headers: bearer_headers(limited)
    assert_response :success
    assert_equal %w[DATABASE_URL],
      response.parsed_body.fetch("snapshots").first.fetch("keys")

    other = create_test_organization
    other_token = issue_test_token(organization: other, permissions: %w[read])
    get "/api/v1/configuration_snapshots",
      params: { repository: "acme/payments", environment: "staging" },
      headers: bearer_headers(other_token)
    assert_response :not_found
  end

  test "names-only collector never accesses or serializes ENV values" do
    secret = Object.new
    def secret.to_s
      raise "secret should not be serialized"
    end
    environment = {
      "DATABASE_URL" => secret, "REDIS_URL" => "secret://value",
      "DEPLOGRAPH_TOKEN" => "client-secret"
    }
    snapshot = Deplograph::RuntimeCollectors::EnvKeysCollector.new(
      env: environment, source: "docker_agent", workload: "payments/web"
    ).collect
    assert_equal %w[DATABASE_URL REDIS_URL], snapshot.fetch("keys")
    assert_equal "partial", snapshot.fetch("completeness")
    refute_includes JSON.generate(snapshot), "secret://value"
    refute_includes JSON.generate(snapshot), "client-secret"

    stub = stub_request(:post, "https://deplograph.example/api/v1/configuration_snapshots")
      .with { |request|
        request.headers["Authorization"] == "Bearer test-observer" &&
          JSON.parse(request.body)["keys"] == %w[DATABASE_URL REDIS_URL]
      }.to_return(status: 201, body: "{}")

    emitter = Deplograph::RuntimeCollectors::EnvKeysEmitter.new(
      url: "https://deplograph.example/api/v1/configuration_snapshots",
      token: "test-observer", repository: "acme/payments", environment: "production"
    )
    assert emitter.send_snapshot(snapshot)
    assert_requested stub
  end

  private

  def snapshot_body(environment:, keys:, source: "github_actions", scope: "declared",
                    completeness: "complete", collected_at: Time.current.utc.iso8601)
    {
      repository: "acme/payments", environment: environment, source: source,
      scope: scope, workload: "web", collection_id: SecureRandom.uuid,
      completeness: completeness, collected_at: collected_at, keys: keys
    }
  end

  def post_snapshot(body, token: @reporter)
    post "/api/v1/configuration_snapshots", params: JSON.generate(body),
      headers: bearer_headers(token)
  end

  def create_snapshot(environment:, keys:, source: "github_actions", scope: "declared",
                      completeness: "complete", collected_at: Time.current.utc.iso8601,
                      token: @reporter, expected_status: :created)
    post_snapshot(snapshot_body(environment: environment, keys: keys, source: source,
      scope: scope, completeness: completeness, collected_at: collected_at), token: token)
    assert_response expected_status
  end

  def compare_names
    post "/api/v1/configuration/drift", params: JSON.generate(
      repository: "acme/payments", baseline_environment: "staging",
      target_environment: "production", workload: "web", scope: "declared"
    ), headers: bearer_headers(@reader)
  end
end
