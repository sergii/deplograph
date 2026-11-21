require "test_helper"

class ReleaseLifecycleTest < ActionDispatch::IntegrationTest
  setup do
    @organization = create_test_organization
    @tokens = {}
    @tokens["api"] = issue_test_token(organization: @organization, provider: "api")
    @tokens["github_actions"] = issue_test_token(
      organization: @organization, provider: "github_actions",
      permissions: %w[report]
    )
    @tokens["kamal"] = issue_test_token(
      organization: @organization, provider: "kamal",
      permissions: %w[report]
    )
    @tokens["kubernetes"] = issue_test_token(
      organization: @organization, provider: "kubernetes",
      permissions: %w[observe]
    )
    @repository = "acme/rails-app"
    @sha_a = "b" * 40
    @sha_b = "c" * 40
    @digest_a = "sha256:" + "a" * 64
    @digest_b = "sha256:" + "b" * 64
    @artifact_a = "oci:ghcr.io/acme/rails-app@#{@digest_a}"
    @artifact_b = "oci:ghcr.io/acme/rails-app@#{@digest_b}"
    @current_time = Time.current.utc.iso8601
  end

  test "GitHub Actions and Kamal report one deployment with Kubernetes evidence" do
    register_release("1.0", @sha_a, @artifact_a, @digest_a)
    register_release("1.1", @sha_b, @artifact_b, @digest_b)
    snapshot_a = import_inventory(@sha_a, @artifact_a, @digest_a)
    snapshot_b = import_inventory(@sha_b, @artifact_b, @digest_b)

    vulnerability = Vulnerability.create!(identifier: "CVE-SIMULATED-0001")
    occurrence = snapshot_a.component_occurrences.first
    snapshot_a.vulnerability_matches.create!(
      component_occurrence: occurrence,
      vulnerability: vulnerability, source: "simulation"
    )
    snapshot_a.update!(match_status: "completed")
    snapshot_b.update!(match_status: "completed")

    production_report = event("production", "github_actions", "deployment.reported",
      "gh-100", "production-deploy-1", "1.0", @artifact_a, @digest_a)
    send_event(production_report)
    send_event(event("production", "kamal", "deployment.reported",
      "kamal-100", "production-deploy-1", "1.0", @artifact_a, @digest_a))
    send_event(event("production", "kubernetes", "artifact.observed",
      "k8s-web-100", "production-deploy-1", "1.0", @artifact_a, @digest_a,
      workload: "web"))

    send_event(event("staging", "github_actions", "deployment.reported",
      "gh-101", "staging-deploy-1", "1.1", @artifact_b, @digest_b))
    send_event(event("staging", "kubernetes", "artifact.observed",
      "k8s-web-101", "staging-deploy-1", "1.1", @artifact_b, @digest_b,
      workload: "web"))

    assert_equal 2, Deployment.count
    assert_equal 5, DeploymentEvent.count
    assert_equal 2, DeploymentObservation.count
    assert_equal %w[reported], Deployment.distinct.pluck(:status).sort
    assert_equal 2, Release.count
    assert_equal 2, Build.count

    get "/api/v1/environments", params: { repository: @repository }, headers: auth_headers
    assert_response :success
    environments = response.parsed_body.fetch("environments").index_by { |entry| entry.fetch("name") }
    production = environments.fetch("production").fetch("observed").first
    staging = environments.fetch("staging").fetch("observed").first
    assert_equal %w[github_actions kamal],
      environments.fetch("production").fetch("reported").fetch("reporting_sources")
    assert_equal "kubernetes", production.fetch("source")
    assert_equal "partial", environments.fetch("production").fetch("verification_status")
    assert_equal "partial", environments.fetch("staging").fetch("verification_status")
    assert_equal @digest_a, production.fetch("image_digest")
    assert_equal @digest_b, staging.fetch("image_digest")
    assert_equal ["CVE-SIMULATED-0001"], production.fetch("vulnerability_ids")
    assert_empty staging.fetch("vulnerability_ids")
    assert_equal "completed", staging.fetch("inventory_status")
    assert_equal "1.0", environments.fetch("production").fetch("reported").fetch("release")
    assert_equal "1.1", environments.fetch("staging").fetch("reported").fetch("release")
  end

  test "replayed events are idempotent but conflicting event IDs are rejected" do
    register_release("1.0", @sha_a, @artifact_a, @digest_a)
    body = event("production", "github_actions", "deployment.reported",
      "gh-100", "production-deploy-1", "1.0", @artifact_a, @digest_a)

    2.times { send_event(body) }
    assert_equal 1, DeploymentEvent.count
    assert_equal 1, Deployment.count

    altered = body.merge("deployment_id" => "different-deployment")
    post "/api/v1/integration_events", params: JSON.generate(altered), headers: bearer_headers(@tokens.fetch("github_actions"))
    assert_response :conflict
    assert_equal 1, Deployment.count
  end

  test "CI cannot impersonate a runtime observer" do
    body = event("production", "github_actions", "artifact.observed",
      "bad-observation", "prod-1", nil, @artifact_a, @digest_a, workload: "web")

    post "/api/v1/integration_events", params: JSON.generate(body), headers: bearer_headers(@tokens.fetch("github_actions"))
    assert_response :forbidden
    assert_equal 0, DeploymentObservation.count
  end

  test "mixed rollout retains differing runtime digests and older observations do not replace newer ones" do
    register_release("1.0", @sha_a, @artifact_a, @digest_a)
    register_release("1.1", @sha_b, @artifact_b, @digest_b)
    send_event(event("production", "github_actions", "deployment.reported",
      "gh-mixed", "production-deploy-1", "1.0", @artifact_a, @digest_a))
    send_event(event("production", "kubernetes", "artifact.observed",
      "k8s-new", "production-deploy-1", nil, @artifact_b, @digest_b, workload: "web"))
    older = event("production", "kubernetes", "artifact.observed",
      "k8s-old", "production-deploy-1", nil, @artifact_a, @digest_a, workload: "web")
    older["occurred_at"] = (Time.current - 60).utc.iso8601
    send_event(older)

    get "/api/v1/environments", params: { repository: @repository }, headers: auth_headers
    assert_response :success
    production = response.parsed_body.fetch("environments").find { |env| env["name"] == "production" }
    assert_equal @digest_b, production.fetch("observed").first.fetch("image_digest")
    assert_equal @artifact_a, production.fetch("reported").fetch("artifact")
    assert_equal "conflicting_observation", production.fetch("verification_status")
    assert_equal "reported", Deployment.last.status
    assert_equal 1, Deployment.count
    assert_equal 2, DeploymentObservation.count
  end

  private

  def register_release(name, sha, identifier, digest)
    body = {
      repository: @repository, release: name, commit_sha: sha,
      build: { provider: "github_actions", id: "build-#{name}" },
      artifacts: [{ identifier: identifier, image_digest: digest }]
    }
    post "/api/v1/releases", params: JSON.generate(body), headers: bearer_headers(@tokens.fetch("github_actions"))
    assert_response :created
  end

  def import_inventory(sha, identifier, digest)
    sbom = JSON.parse(File.read(Rails.root.join("examples/sample_cyclonedx.json")))
    body = {
      repository: @repository, artifact_identifier: identifier,
      artifact_kind: "image", image_digest: digest,
      commit_sha: sha, format: "cyclonedx", sbom: sbom
    }
    post "/api/v1/inventories", params: JSON.generate(body), headers: auth_headers
    assert_response :created
    InventorySnapshot.find(response.parsed_body.fetch("inventory_snapshot_id"))
  end

  def event(environment, source, type, event_id, deployment_id, release, artifact, digest, workload: nil)
    body = {
      "repository" => @repository,
      "environment" => environment,
      "source" => source,
      "event_type" => type,
      "event_id" => event_id,
      "deployment_id" => deployment_id,
      "occurred_at" => @current_time,
      "artifact_identifier" => artifact,
      "image" => "ghcr.io/acme/rails-app",
      "image_digest" => digest
    }
    body["release"] = release if release
    body["workload"] = workload if workload
    body
  end

  def send_event(body)
    headers = bearer_headers(@tokens.fetch(body.fetch("source")))
    post "/api/v1/integration_events", params: JSON.generate(body), headers: headers
    assert_response :accepted, response.body
  end

  def auth_headers
    bearer_headers(@tokens.fetch("api"))
  end
end
