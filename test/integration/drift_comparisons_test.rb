require "test_helper"

class DriftComparisonsTest < ActionDispatch::IntegrationTest
  setup do
    @organization = create_test_organization
    @token = issue_test_token(
      organization: @organization, provider: "api",
      permissions: %w[read], repository_scopes: ["acme/payments"]
    )
    @application = @organization.applications.create!(
      name: "Payments", repository_full_name: "acme/payments"
    )
    @production = @application.environments.create!(name: "production", kind: "production")
    @staging = @application.environments.create!(name: "staging", kind: "staging")
    @production_artifact = create_artifact("a")
    @staging_artifact = create_artifact("b")
    @production_release = @application.releases.create!(name: "v1.8.0")
    @staging_release = @application.releases.create!(name: "v1.9.0")
    deploy(@production, @production_artifact, @production_release, "prod-1")
    deploy(@staging, @staging_artifact, @staging_release, "stage-1")
  end

  test "reports dependency, image, release and security drift between staging and production" do
    production_snapshot = import(@production_artifact, rack: "3.1.0")
    staging_snapshot = import(@staging_artifact, rack: "3.2.0")
    mark_scanned(production_snapshot, "GHSA-production-only")
    mark_scanned(staging_snapshot)

    post_compare
    assert_response :created
    comparison = response.parsed_body.fetch("result")
    assert_equal "different", comparison.fetch("status")
    assert_equal "reported", comparison.fetch("mode")
    assert_equal false, comparison.fetch("verified_runtime")
    assert_equal "partial", comparison.fetch("confidence")

    dimensions = comparison.fetch("dimensions")
    assert_equal "different", dimensions.fetch("release").fetch("status")
    assert_equal "different", dimensions.fetch("artifact").fetch("status")
    changed = dimensions.fetch("dependencies").fetch("version_changed")
    assert_equal 1, changed.size
    assert_equal "gem:rack", changed.first.fetch("package")
    assert_equal ["3.2.0"], changed.first.fetch("baseline_versions")
    assert_equal ["3.1.0"], changed.first.fetch("target_versions")
    assert_equal ["GHSA-production-only"],
      dimensions.fetch("security").fetch("only_in_target")
    assert_empty dimensions.fetch("security").fetch("only_in_baseline")

    assert_equal @production_artifact.image_digest,
      comparison.fetch("target").fetch("workloads").first.fetch("artifact_identifier")
    assert_equal production_snapshot.id,
      comparison.fetch("target").fetch("workloads").first.fetch("inventory_snapshot_id")
    assert_equal 1, @organization.drift_comparisons.count
  end

  test "unscanned or missing inventory never becomes a clean result" do
    import(@production_artifact, rack: "3.1.0")
    post_compare

    assert_response :created
    result = response.parsed_body.fetch("result")
    assert_equal "unknown", result.dig("dimensions", "dependencies", "status")
    assert_equal "unknown", result.dig("dimensions", "security", "status")
    assert_equal "partial", result.fetch("confidence")
    assert_includes result.fetch("incomplete_dimensions"), "security"
    assert_includes result.fetch("incomplete_dimensions"), "dependencies"
    assert_equal false, result.fetch("verified_runtime")
  end

  test "same partial inventory is never treated as verified absence of drift" do
    shared = create_artifact("c")
    deploy(@production, shared, @production_release, "prod-2")
    deploy(@staging, shared, @production_release, "stage-2")
    snapshot = import(shared, rack: "3.2.0")
    mark_scanned(snapshot)

    post_compare
    assert_response :created
    result = response.parsed_body.fetch("result")
    assert_equal "partial", result.fetch("status")
    assert_equal "partial", result.dig("dimensions", "dependencies", "status")
    assert_equal "partial", result.dig("dimensions", "security", "status")
    assert_equal "same", result.dig("dimensions", "dependencies", "known_relation")
    assert_equal false, result.fetch("verified_runtime")
  end

  test "runtime observations may show conflicting images but cannot verify full rollout" do
    observed(@staging, @staging_artifact, event: "staging-pod", workload: "web")
    observed(@production, @production_artifact, event: "prod-pod", workload: "web")
    import(@production_artifact, rack: "3.1.0")
    import(@staging_artifact, rack: "3.2.0")

    post_compare(mode: "observed")
    assert_response :created
    result = response.parsed_body.fetch("result")
    assert_equal "different", result.fetch("status")
    assert_equal "partial", result.fetch("confidence")
    assert_equal false, result.fetch("verified_runtime")
    assert_equal "unknown", result.dig("dimensions", "release", "status")
    assert_equal "partial_runtime_observation",
      result.dig("target", "evidence_level")
  end

  test "stale OSV results remain visibly stale instead of being treated as fixed" do
    prod = import(@production_artifact, rack: "3.1.0")
    stage = import(@staging_artifact, rack: "3.2.0")
    mark_scanned(prod)
    mark_scanned(stage)
    prod.update!(match_completed_at: 3.days.ago)

    post_compare
    assert_response :created
    assert_equal "stale",
      response.parsed_body.dig("result", "dimensions", "security", "status")
  end

  test "stale observations do not assert current drift even when historic images differed" do
    observed(@staging, @staging_artifact, event: "stage-stale", workload: "web")
    observed(@production, @production_artifact, event: "prod-stale", workload: "web")
    DeploymentObservation.update_all(observed_at: 3.hours.ago)
    import(@production_artifact, rack: "3.1.0")
    import(@staging_artifact, rack: "3.2.0")

    post_compare(mode: "observed")
    assert_response :created
    result = response.parsed_body.fetch("result")
    assert_equal "stale", result.fetch("status")
    assert_equal true, result.fetch("baseline").fetch("stale")
    assert_equal true, result.fetch("target").fetch("stale")
    assert_equal false, result.fetch("verified_runtime")
  end

  test "no runtime observations means unknown, not equal deployment state" do
    post_compare(mode: "observed")
    assert_response :created
    result = response.parsed_body.fetch("result")
    assert_equal "unknown", result.fetch("status")
    assert_equal false, result.fetch("verified_runtime")
  end

  test "history and individual comparisons remain isolated by tenant and environment scope" do
    import(@production_artifact, rack: "3.1.0")
    import(@staging_artifact, rack: "3.2.0")
    post_compare
    assert_response :created
    id = response.parsed_body.fetch("id")

    get "/api/v1/drift/comparisons", params: { repository: "acme/payments" },
      headers: bearer_headers(@token)
    assert_response :success
    assert_equal 1, response.parsed_body.fetch("comparisons").size

    get "/api/v1/drift/comparisons/#{id}", headers: bearer_headers(@token)
    assert_response :success

    other = create_test_organization
    token = issue_test_token(organization: other, permissions: %w[read])
    get "/api/v1/drift/comparisons/#{id}", headers: bearer_headers(token)
    assert_response :not_found

    limited = issue_test_token(
      organization: @organization, permissions: %w[read],
      repository_scopes: ["acme/payments"], environment_scopes: ["staging"]
    )
    post "/api/v1/drift/comparisons",
      params: JSON.generate(repository: "acme/payments",
        baseline_environment: "staging", target_environment: "production"),
      headers: bearer_headers(limited)
    assert_response :forbidden
    assert_equal 1, DriftComparison.count

    get "/api/v1/drift/comparisons/#{id}", headers: bearer_headers(limited)
    assert_response :forbidden
    get "/api/v1/drift/comparisons", params: { repository: "acme/payments" },
      headers: bearer_headers(limited)
    assert_response :success
    assert_empty response.parsed_body.fetch("comparisons")
  end

  private

  def create_artifact(char)
    digest = "sha256:" + char * 64
    @application.artifacts.create!(
      kind: "image", image_digest: digest,
      identifier: "oci:ghcr.io/acme/payments@#{digest}"
    )
  end

  def deploy(environment, artifact, release, id)
    environment.deployments.create!(
      artifact: artifact, release: release, external_id: id,
      provider: "github_actions", deployed_at: Time.current, status: "reported"
    )
  end

  def observed(environment, artifact, event:, workload:)
    environment.deployment_observations.create!(
      artifact: artifact, source: "kubernetes", event_id: event,
      workload: workload, image_digest: artifact.image_digest, observed_at: Time.current
    )
  end

  def import(artifact, rack:)
    document = {
      "bomFormat" => "CycloneDX", "specVersion" => "1.6",
      "components" => [
        { "bom-ref" => "rack", "name" => "rack", "version" => rack,
          "purl" => "pkg:gem/rack@#{rack}" },
        { "bom-ref" => "rails", "name" => "rails", "version" => "8.1.4",
          "purl" => "pkg:gem/rails@8.1.4" }
      ]
    }
    Inventory::Importer.new.call(
      application: @application, artifact_identifier: artifact.identifier,
      image_digest: artifact.image_digest, kind: "image",
      document: document, format: "cyclonedx"
    )
  end

  def mark_scanned(snapshot, advisory = nil)
    if advisory
      vulnerability = Vulnerability.find_or_create_by!(identifier: advisory)
      snapshot.vulnerability_matches.create!(
        component_occurrence: snapshot.component_occurrences.first,
        vulnerability: vulnerability, source: "simulation"
      )
    end
    snapshot.update!(match_status: "completed", match_completed_at: Time.current)
  end

  def post_compare(mode: "reported")
    post "/api/v1/drift/comparisons",
      params: JSON.generate(repository: "acme/payments",
        baseline_environment: "staging", target_environment: "production", mode: mode),
      headers: bearer_headers(@token)
  end
end
