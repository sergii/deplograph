require "test_helper"
require "openssl"
require "json"

class ConfigurationFingerprintsTest < ActionDispatch::IntegrationTest
  setup do
    @organization = create_test_organization
    @reporter = issue_test_token(
      organization: @organization, provider: "github_actions", permissions: %w[report],
      repository_scopes: ["acme/payments"]
    )
    @reader = issue_test_token(
      organization: @organization, provider: "api", permissions: %w[read],
      repository_scopes: ["acme/payments"]
    )
    @manager = issue_test_token(
      organization: @organization, provider: "api", permissions: %w[manage],
      repository_scopes: ["acme/payments"]
    )
    @secret = "test-only-random-HMAC-key-32-bytes-minimum-#{SecureRandom.hex(20)}"
    @values = {
      "staging" => {
        "DATABASE_URL" => "stage-postgres", "API_KEY" => "same-secret",
        "FEATURE_FLAG" => "off", "LOG_LEVEL" => "debug"
      },
      "production" => {
        "DATABASE_URL" => "prod-postgres", "API_KEY" => "changed-secret",
        "FEATURE_FLAG" => "on", "LOG_LEVEL" => "info"
      }
    }
  end

  test "policy engine distinguishes expected differences from violations without returning HMACs" do
    create_both_snapshots_and_fingerprints
    put_policy(name: "DATABASE_URL", rule: "must_differ")
    put_policy(name: "FEATURE_FLAG", rule: "allowed_to_differ")
    put_policy(name: "LOG_LEVEL", rule: "ignore")

    compare
    assert_response :created
    body = response.parsed_body
    assert_equal "different", body.fetch("status")
    assert_equal false, body.dig("result", "plaintext_collected")
    assert_equal false, body.dig("result", "verified_runtime")

    dimension = body.dig("result", "dimensions", "environment_value_fingerprints")
    assert_equal ["API_KEY"], dimension.fetch("policy_violations")
    evaluations = dimension.fetch("comparisons").index_by { |entry| entry.fetch("name") }
    assert_equal "must_differ", evaluations.fetch("DATABASE_URL").fetch("policy")
    assert_equal "compliant", evaluations.fetch("DATABASE_URL").fetch("evaluation")
    assert_equal "allowed_to_differ", evaluations.fetch("FEATURE_FLAG").fetch("policy")
    assert_equal "ignored", evaluations.fetch("LOG_LEVEL").fetch("evaluation")
    assert_equal "violation", evaluations.fetch("API_KEY").fetch("evaluation")
    assert_equal "different", evaluations.fetch("API_KEY").fetch("value_relation")
    refute_includes JSON.generate(body), @secret
    refute_includes JSON.generate(body), "changed-secret"
    refute_includes JSON.generate(body), fingerprint_for("acme/payments", "API_KEY", "same-secret")

    # An explicit exception may be added by an authorized manager.
    put_policy(name: "API_KEY", rule: "allowed_to_differ")
    compare
    assert_response :created
    assert_equal "same", response.parsed_body.fetch("status")
    assert_equal 2, DriftComparison.where(mode: "configuration_fingerprints").count
    assert_equal 4, ConfigurationPolicyChange.count
  end

  test "must_differ is violated when a value fingerprint is equal" do
    @values["production"]["API_KEY"] = "same-secret"
    create_both_snapshots_and_fingerprints
    put_policy(name: "API_KEY", rule: "must_differ")

    compare
    assert_response :created
    dimension = response.parsed_body.dig("result", "dimensions", "environment_value_fingerprints")
    assert_includes dimension.fetch("policy_violations"), "API_KEY"
    assert_equal "equal",
      dimension.fetch("comparisons").find { |item| item["name"] == "API_KEY" }.fetch("value_relation")
  end

  test "different HMAC key IDs never claim a changed or equal value" do
    ids = create_both_snapshots_and_fingerprints(production_key_id: "key-rotation-2")
    compare
    assert_response :created
    dimension = response.parsed_body.dig("result", "dimensions", "environment_value_fingerprints")
    assert_equal "unknown", dimension.fetch("status")
    assert_match(/key IDs/, dimension.fetch("reason"))
    assert_equal false, dimension.fetch("values_compared")
    assert_equal 2, ConfigurationFingerprintBatch.count
    assert_equal 2, ids.size
  end

  test "missing and partial fingerprint uploads cannot produce a clean result" do
    ids = create_both_snapshots
    post_fingerprints(ids.fetch("staging"), @values.fetch("staging"))
    compare
    assert_response :created
    assert_equal "unknown", response.parsed_body.fetch("status")

    post_fingerprints(ids.fetch("production"), @values.fetch("production").slice("DATABASE_URL"))
    compare
    assert_response :created
    dimension = response.parsed_body.dig("result", "dimensions", "environment_value_fingerprints")
    assert_equal "partial", dimension.fetch("status")
    assert_includes dimension.fetch("unresolved_keys"), "API_KEY"
    assert_equal "partial", dimension.fetch("confidence")
  end

  test "fingerprint upload validates names, digest syntax and conflicts without storing values" do
    ids = create_both_snapshots
    id = ids.fetch("staging")
    data = fingerprint_body(id, @values.fetch("staging"))
    2.times do
      post_fingerprint_body(data)
      assert_response :created
    end
    assert_equal 1, ConfigurationFingerprintBatch.count
    assert_equal 4, ConfigurationFingerprint.count

    changed = data.deep_dup
    changed[:fingerprints]["API_KEY"] = "a" * 64
    post_fingerprint_body(changed)
    assert_response :conflict
    assert_equal 1, ConfigurationFingerprintBatch.count

    invalid = data.deep_dup
    invalid[:key_id] = "another-key"
    invalid[:fingerprints]["API_KEY"] = "postgres://plaintext-value"
    post_fingerprint_body(invalid)
    assert_response :unprocessable_entity

    invalid[:fingerprints]["API_KEY"] = "b" * 64
    invalid[:fingerprints]["UNDECLARED_SECRET"] = "c" * 64
    post_fingerprint_body(invalid)
    assert_response :unprocessable_entity

    invalid.delete(:fingerprints)
    invalid[:values] = { "API_KEY" => "secret" }
    post_fingerprint_body(invalid)
    assert_response :unprocessable_entity
    assert_equal 1, ConfigurationFingerprintBatch.count
  end

  test "credential permissions and organization boundaries guard fingerprint ingestion and policy writes" do
    ids = create_both_snapshots
    data = fingerprint_body(ids.fetch("staging"), @values.fetch("staging"))

    post_fingerprint_body(data, token: @reader)
    assert_response :forbidden

    other = create_test_organization
    other_token = issue_test_token(organization: other, provider: "github_actions",
      permissions: %w[report], repository_scopes: ["acme/payments"])
    post_fingerprint_body(data, token: other_token)
    assert_response :not_found

    scoped = issue_test_token(organization: @organization,
      provider: "github_actions", permissions: %w[report],
      repository_scopes: ["acme/payments"], environment_scopes: ["production"])
    post_fingerprint_body(data, token: scoped)
    assert_response :forbidden

    put_policy(name: "API_KEY", rule: "ignore", token: @reader)
    assert_response :forbidden
    assert_equal 0, ConfigurationPolicy.count

    put_policy(name: "API_KEY", rule: "ignore", token: @manager)
    assert_response :ok
    assert_equal 1, ConfigurationPolicy.count
    assert_equal 1, ConfigurationPolicyChange.count
  end

  test "policy replacement is audited and replay is idempotent" do
    create_both_snapshots
    put_policy(name: "API_KEY", rule: "must_match")
    put_policy(name: "API_KEY", rule: "must_match")
    assert_equal 1, ConfigurationPolicyChange.count

    put_policy(name: "API_KEY", rule: "allowed_to_differ")
    assert_equal 2, ConfigurationPolicyChange.count
    assert_equal ["must_match", "allowed_to_differ"],
      ConfigurationPolicyChange.order(:id).pluck(:new_rule)

    get "/api/v1/configuration/policies", params: {
      repository: "acme/payments",
      baseline_environment: "staging", target_environment: "production"
    }, headers: bearer_headers(@reader)
    assert_response :success
    assert_equal "allowed_to_differ", response.parsed_body.fetch("policies").first.fetch("rule")
  end

  test "stale names-only evidence yields stale fingerprint comparison" do
    ids = create_both_snapshots
    post_fingerprints(ids.fetch("staging"), @values.fetch("staging"))
    post_fingerprints(ids.fetch("production"), @values.fetch("production"))
    ConfigurationSnapshot.update_all(collected_at: 2.days.ago)

    compare
    assert_response :created
    assert_equal "stale", response.parsed_body.fetch("status")
  end

  private

  def create_both_snapshots
    @values.to_h do |environment, variables|
      body = {
        repository: "acme/payments", environment: environment,
        source: "github_actions", scope: "declared", workload: "web",
        completeness: "complete", collected_at: Time.current.utc.iso8601,
        collection_id: SecureRandom.uuid, keys: variables.keys
      }
      post "/api/v1/configuration_snapshots",
        params: JSON.generate(body), headers: bearer_headers(@reporter)
      assert_response :created
      [environment, response.parsed_body.fetch("id")]
    end
  end

  def create_both_snapshots_and_fingerprints(production_key_id: "shared-v1")
    ids = create_both_snapshots
    post_fingerprints(ids.fetch("staging"), @values.fetch("staging"))
    post_fingerprints(ids.fetch("production"), @values.fetch("production"),
      key_id: production_key_id)
    ids
  end

  def fingerprint_for(repository, name, value)
    OpenSSL::HMAC.hexdigest("SHA256", @secret,
      JSON.generate(["deplograph-env-value-v1", repository, name, value]))
  end

  def fingerprint_body(snapshot_id, values, key_id: "shared-v1")
    {
      repository: "acme/payments",
      environment: ConfigurationSnapshot.find(snapshot_id).environment.name,
      snapshot_id: snapshot_id, key_id: key_id, algorithm: "HMAC-SHA256-v1",
      fingerprints: values.transform_keys(&:to_s).to_h do |name, value|
        [name, fingerprint_for("acme/payments", name, value)]
      end
    }
  end

  def post_fingerprints(snapshot_id, values, key_id: "shared-v1")
    post_fingerprint_body(fingerprint_body(snapshot_id, values, key_id: key_id))
    assert_response :created
  end

  def post_fingerprint_body(body, token: @reporter)
    post "/api/v1/configuration/fingerprints",
      params: JSON.generate(body), headers: bearer_headers(token)
  end

  def put_policy(name:, rule:, token: @manager)
    put "/api/v1/configuration/policies", params: JSON.generate(
      repository: "acme/payments",
      baseline_environment: "staging", target_environment: "production",
      workload: "web", scope: "declared", name: name, rule: rule
    ), headers: bearer_headers(token)
  end

  def compare
    post "/api/v1/configuration/fingerprints/drift",
      params: JSON.generate(
        repository: "acme/payments",
        baseline_environment: "staging", target_environment: "production",
        workload: "web", scope: "declared"
      ), headers: bearer_headers(@reader)
  end
end
