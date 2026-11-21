require "test_helper"

class HardeningTest < ActionDispatch::IntegrationTest
  setup do
    @organization = create_test_organization
    @api_token = issue_test_token(organization: @organization)
    @github_token = issue_test_token(
      organization: @organization, provider: "github_actions", permissions: %w[report]
    )
    @kubernetes_credential, @kubernetes_token = IntegrationCredential.issue!(
      organization: @organization, name: "Kubernetes observer", provider: "kubernetes",
      permissions: %w[observe]
    )
  end

  test "a generic ingestion token never authorizes runtime observations" do
    post "/api/v1/integration_events",
      params: JSON.generate(observation("kubernetes")),
      headers: auth(@api_token)

    assert_response :forbidden
    assert_equal 0, DeploymentObservation.count
    assert_equal 0, DeploymentEvent.count
  end

  test "observer tokens are bound to their provider identity" do
    post "/api/v1/integration_events",
      params: JSON.generate(observation("kamal_agent")),
      headers: auth(@kubernetes_token)
    assert_response :forbidden

    post "/api/v1/integration_events",
      params: JSON.generate(observation("kubernetes")),
      headers: auth(@kubernetes_token)
    assert_response :accepted
    assert_equal 1, DeploymentObservation.count
    assert_equal "kubernetes", DeploymentObservation.last.source
  end

  test "a revoked observer cannot make observations" do
    @kubernetes_credential.revoke!
    post "/api/v1/integration_events",
      params: JSON.generate(observation("kubernetes")),
      headers: auth(@kubernetes_token)

    assert_response :unauthorized
    assert_equal 0, DeploymentObservation.count
  end

  test "legacy deployments use the evidence pipeline and do not revive destroyed previews" do
    payload = JSON.parse(File.read(Rails.root.join("examples/sample_deployment.json")))
    payload["environment"] = "preview-123-1"
    payload["environment_kind"] = "preview"
    payload["deployed_at"] = Time.current.utc.iso8601

    2.times do
      post "/api/v1/deployments", params: JSON.generate(payload), headers: auth(@github_token)
      assert_response :created
    end
    assert_equal 1, Deployment.count
    assert_equal 1, DeploymentEvent.count

    lifecycle = {
      repository: payload.fetch("repository"),
      environment: payload.fetch("environment"),
      kind: "preview", event: "destroyed"
    }
    post "/api/v1/environment_events", params: JSON.generate(lifecycle), headers: auth(@api_token)
    assert_response :created
    assert_equal "destroyed", Environment.last.reload.state

    post "/api/v1/deployments", params: JSON.generate(payload), headers: auth(@github_token)
    assert_response :conflict
    assert_equal "destroyed", Environment.last.reload.state
    assert_equal 1, Deployment.count
    assert_equal 1, DeploymentEvent.count
  end

  test "artifact digest and commit identity cannot be overwritten by another import" do
    digest = "sha256:" + "a" * 64
    identifier = "oci:ghcr.io/acme/app@#{digest}"
    initial = inventory(identifier: identifier, digest: digest, commit: "a" * 40)

    post "/api/v1/inventories", params: JSON.generate(initial), headers: auth(@api_token)
    assert_response :created
    artifact = Artifact.last

    altered_commit = inventory(identifier: identifier, digest: digest, commit: "b" * 40)
    post "/api/v1/inventories", params: JSON.generate(altered_commit), headers: auth(@api_token)
    assert_response :conflict
    assert_equal "a" * 40, artifact.reload.commit_sha

    altered_digest = inventory(identifier: identifier, digest: "sha256:" + "c" * 64, commit: "a" * 40)
    post "/api/v1/inventories", params: JSON.generate(altered_digest), headers: auth(@api_token)
    assert_response :conflict
    assert_equal digest, artifact.reload.image_digest
    assert_equal 1, InventorySnapshot.count

    refute artifact.update(image_digest: "sha256:" + "d" * 64)
    assert_equal digest, artifact.reload.image_digest
  end

  test "a single matching pod does not verify an entire deployment" do
    digest = "sha256:" + "a" * 64
    identifier = "oci:ghcr.io/acme/app@#{digest}"
    reported = {
      repository: "acme/app", environment: "production",
      provider: "github_actions", deployment_id: "deploy-123",
      image: "ghcr.io/acme/app", image_digest: digest,
      artifact_identifier: identifier, deployed_at: Time.current.utc.iso8601
    }
    post "/api/v1/deployments", params: JSON.generate(reported), headers: auth(@github_token)
    assert_response :created

    observed = observation("kubernetes").merge(
      "repository" => "acme/app", "environment" => "production",
      "deployment_id" => "deploy-123", "image" => "ghcr.io/acme/app",
      "artifact_identifier" => identifier, "image_digest" => digest
    )
    post "/api/v1/integration_events", params: JSON.generate(observed), headers: auth(@kubernetes_token)
    assert_response :accepted

    assert_equal "reported", Deployment.last.reload.status
    get "/api/v1/environments", params: { repository: "acme/app" }, headers: auth(@api_token)
    assert_response :success
    environment = response.parsed_body.fetch("environments").first
    assert_equal "partial", environment.fetch("verification_status")
    assert_equal "reported", environment.fetch("reported").fetch("status")
  end

  private

  def auth(token)
    { "CONTENT_TYPE" => "application/json", "Authorization" => "Bearer #{token}" }
  end

  def observation(source)
    digest = "sha256:" + "a" * 64
    {
      "repository" => "acme/app",
      "environment" => "production",
      "source" => source,
      "event_type" => "artifact.observed",
      "event_id" => "obs-123",
      "occurred_at" => Time.current.utc.iso8601,
      "deployment_id" => "dep-1",
      "workload" => "web",
      "image" => "ghcr.io/acme/app",
      "image_digest" => digest,
      "artifact_identifier" => "oci:ghcr.io/acme/app@#{digest}"
    }
  end

  def inventory(identifier:, digest:, commit:)
    {
      repository: "acme/app", artifact_identifier: identifier, artifact_kind: "image",
      image_digest: digest, commit_sha: commit,
      format: "cyclonedx",
      sbom: JSON.parse(File.read(Rails.root.join("examples/sample_cyclonedx.json")))
    }
  end
end
