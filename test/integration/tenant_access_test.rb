require "test_helper"

class TenantAccessTest < ActionDispatch::IntegrationTest
  setup do
    @first = create_test_organization(slug: "tenant-first")
    @second = create_test_organization(slug: "tenant-second")
    @first_token = issue_test_token(organization: @first)
    @second_token = issue_test_token(organization: @second)
    @repository = "acme/shared-name"
  end

  test "identical repository names are isolated by organization" do
    import(@first_token, @repository, "git:first")
    import(@second_token, @repository, "git:second")

    assert_equal 2, Application.where(repository_full_name: @repository).count
    assert_equal 1, @first.applications.count
    assert_equal 1, @second.applications.count

    get "/api/v1/releases", params: { repository: @repository },
      headers: bearer_headers(@first_token)
    assert_response :success

    first = @first.applications.first
    second = @second.applications.first
    assert_equal 1, first.artifacts.count
    assert_equal 1, second.artifacts.count
    assert_equal "git:first", first.artifacts.first.identifier
    assert_equal "git:second", second.artifacts.first.identifier

    get "/api/v1/environments", params: { repository: "acme/only-other" },
      headers: bearer_headers(@first_token)
    assert_response :not_found
  end

  test "repository allowlist blocks unauthorized reads and writes before resource creation" do
    restricted = issue_test_token(
      organization: @first, repository_scopes: ["acme/allowed"]
    )
    import(restricted, "acme/not-allowed", "git:blocked", expected: :forbidden)
    assert_equal 0, @first.applications.count

    import(restricted, "acme/allowed", "git:allowed")
    assert_equal 1, @first.applications.count

    get "/api/v1/environments", params: { repository: "acme/not-allowed" },
      headers: bearer_headers(restricted)
    assert_response :forbidden
  end

  test "environment scope and provider are enforced on deployment events" do
    limited = issue_test_token(
      organization: @first, provider: "github_actions", permissions: %w[report],
      repository_scopes: [@repository], environment_scopes: ["staging"]
    )
    body = report_event(source: "github_actions", environment: "production")

    post "/api/v1/integration_events", params: JSON.generate(body),
      headers: bearer_headers(limited)
    assert_response :forbidden
    assert_equal 0, DeploymentEvent.count

    body[:environment] = "staging"
    body[:source] = "kamal"
    post "/api/v1/integration_events", params: JSON.generate(body),
      headers: bearer_headers(limited)
    assert_response :forbidden

    body[:source] = "github_actions"
    post "/api/v1/integration_events", params: JSON.generate(body),
      headers: bearer_headers(limited)
    assert_response :accepted
    assert_equal 1, DeploymentEvent.count
    assert_equal 1, @first.applications.count
  end

  test "repository inspector does not forward shared GitHub credentials to tenant-selected repos" do
    previous = ENV["GITHUB_TOKEN"]
    ENV["GITHUB_TOKEN"] = "shared-server-token-must-never-be-used"

    request = stub_request(:get, "https://api.github.com/repos/private-org/private-app")
      .with { |incoming| incoming.headers["Authorization"].nil? }
      .to_return(status: 404, body: '{"message":"Not Found"}')

    post "/api/v1/repositories/inspect",
      params: JSON.generate(repository: "private-org/private-app"),
      headers: bearer_headers(@first_token)

    assert_response :bad_gateway
    assert_requested request
  ensure
    ENV["GITHUB_TOKEN"] = previous
  end

  test "read-only credential cannot report and reporter cannot read" do
    reader = issue_test_token(organization: @first, permissions: %w[read])
    reporter = issue_test_token(organization: @first, permissions: %w[report])
    import(reader, @repository, "git:denied", expected: :forbidden)
    import(reporter, @repository, "git:accepted")

    get "/api/v1/releases", params: { repository: @repository },
      headers: bearer_headers(reporter)
    assert_response :forbidden

    get "/api/v1/releases", params: { repository: @repository },
      headers: bearer_headers(reader)
    assert_response :success
  end

  test "expired and revoked credentials fail authentication and are audited" do
    credential, token = IntegrationCredential.issue!(
      organization: @first, name: "revokable", provider: "api",
      permissions: %w[read report]
    )
    assert_equal 1, credential.integration_audit_events.where(action: "issued").count
    refute_equal token, credential.token_digest
    assert_equal 64, credential.token_digest.length

    import(token, @repository, "git:before-revocation")
    credential.revoke!
    assert_equal 1, credential.integration_audit_events.where(action: "revoked").count

    import(token, @repository, "git:after-revocation", expected: :unauthorized)
    assert_nil IntegrationCredential.authenticate("Bearer #{token}")

    expired, expired_token = IntegrationCredential.issue!(
      organization: @first, name: "expired", provider: "api",
      permissions: %w[read report], expires_at: 1.minute.ago
    )
    refute expired.active?
    import(expired_token, @repository, "git:expired", expected: :unauthorized)
    assert_equal 1, InventorySnapshot.count
  end

  private

  def import(token, repository, artifact, expected: :created)
    document = JSON.parse(File.read(Rails.root.join("examples/sample_cyclonedx.json")))
    post "/api/v1/inventories", params: JSON.generate(
      repository: repository, artifact_identifier: artifact, format: "cyclonedx", sbom: document
    ), headers: bearer_headers(token)
    assert_response expected
  end

  def report_event(source:, environment:)
    digest = "sha256:" + "a" * 64
    {
      repository: @repository, environment: environment,
      source: source, event_type: "deployment.reported",
      event_id: "build-1", deployment_id: "deploy-1",
      occurred_at: Time.current.utc.iso8601,
      image: "ghcr.io/acme/app", image_digest: digest,
      artifact_identifier: "oci:ghcr.io/acme/app@#{digest}"
    }
  end
end
