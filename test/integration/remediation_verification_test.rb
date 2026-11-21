require "test_helper"

class RemediationVerificationTest < ActionDispatch::IntegrationTest
  setup do
    @organization = create_test_organization
    @application = @organization.applications.create!(
      name: "Payments", repository_full_name: "acme/payments"
    )
    @staging = @application.environments.create!(name: "staging", kind: "staging")
    @production = @application.environments.create!(name: "production", kind: "production")

    @owner = User.create!(email: "remediation-owner@example.test",
      password: "strong-password-for-tests")
    @viewer = User.create!(email: "remediation-viewer@example.test",
      password: "strong-password-for-tests")
    Membership.create!(user: @owner, organization: @organization, role: "owner")
    Membership.create!(user: @viewer, organization: @organization, role: "viewer")

    @initial = compare_artifact(status: "different", compared_at: 4.hours.ago)
    @finding = @organization.drift_findings.find_by!(category: "artifact_drift")
    digest = "sha256:" + "b" * 64
    @artifact = @application.artifacts.create!(
      kind: "image", image_digest: digest,
      identifier: "oci:ghcr.io/acme/payments@#{digest}"
    )
    @deployment = @production.deployments.create!(
      artifact: @artifact, provider: "github_actions",
      external_id: "deploy-new", deployed_at: 30.minutes.ago,
      status: "reported"
    )
    @reader = issue_test_token(organization: @organization,
      permissions: %w[read], repository_scopes: ["acme/payments"])
  end

  test "a new deployment does not resolve a finding while the discrepancy persists" do
    login(@owner)
    record_applied_deployment
    assert_equal 1, @finding.remediation_attempts.count

    patch finding_path(@finding), params: {
      status: "verification_pending", note: "Deployment reported, checking runtime"
    }
    assert_redirected_to finding_path(@finding)

    travel 2.minutes do
      later = compare_artifact(status: "different", compared_at: Time.current)
      check = @finding.finding_verification_checks.find_by!(drift_comparison: later)
      assert_equal "still_affected", check.outcome
      assert_equal "issue_still_present", check.reason_code
      assert_equal false, check.authoritative
      assert_equal "verification_pending", @finding.reload.status
      assert_nil @finding.resolved_at
      assert_equal later.id, @finding.latest_comparison_id
      assert_equal 1, @finding.finding_verification_checks.count
    end
  end

  test "complete reported comparison can mark candidate clear but cannot claim resolved" do
    login(@owner)
    record_applied_deployment
    patch finding_path(@finding), params: {
      status: "verification_pending", note: "Awaiting fresh comparison"
    }
    assert_redirected_to finding_path(@finding)

    travel 2.minutes do
      newer = compare_artifact(status: "same", compared_at: Time.current)
      check = @finding.finding_verification_checks.find_by!(drift_comparison: newer)
      assert_equal "candidate_clear", check.outcome
      assert_equal "fresh_comparison_no_issue", check.reason_code
      assert_equal false, check.authoritative
      assert_equal "verification_pending", @finding.reload.status
      assert_nil @finding.resolved_at

      get finding_path(@finding)
      assert_response :success
      assert_select "h2", text: "Remediation and verification"
      assert_select "a[href=?]", drift_comparison_path(newer)
      assert_select "form[action=?]", record_finding_remediation_path(@finding)
      assert_select "form[action=?]", verify_finding_path(@finding)

      # Checking the same immutable comparison twice is idempotent.
      post verify_finding_path(@finding), params: { comparison_id: newer.id }
      assert_redirected_to finding_path(@finding)
      assert_equal 1, @finding.finding_verification_checks.count

      patch finding_path(@finding), params: { status: "resolved" }
      assert_response :unprocessable_entity
      assert_nil @finding.reload.resolved_at
    end
  end

  test "planned or unrelated remediation evidence cannot clear findings" do
    login(@owner)
    post record_finding_remediation_path(@finding), params: {
      status: "planned", description: "Fix Rails dependency and redeploy",
      reference_url: "https://github.com/acme/payments/pull/101"
    }
    assert_redirected_to finding_path(@finding)

    travel 2.minutes do
      newer = compare_artifact(status: "same", compared_at: Time.current)
      post verify_finding_path(@finding), params: { comparison_id: newer.id }
      assert_redirected_to finding_path(@finding)
      check = @finding.finding_verification_checks.find_by!(drift_comparison: newer)
      assert_equal "inconclusive", check.outcome
      assert_equal "newer_remediation_required", check.reason_code
      assert_nil check.remediation_attempt_id
      assert_equal "open", @finding.reload.status
    end
  end

  test "reported applied is rejected without a linked deployment or completed scan" do
    login(@owner)
    post record_finding_remediation_path(@finding), params: {
      status: "reported_applied", description: "PR is merged",
      reference_url: "https://github.com/acme/payments/pull/2"
    }
    assert_response :unprocessable_entity
    assert_equal 0, @finding.remediation_attempts.count

    post record_finding_remediation_path(@finding), params: {
      status: "planned", description: "Need credentials",
      reference_url: "http://not-https.example/path"
    }
    assert_response :unprocessable_entity
    assert_equal 0, @finding.remediation_attempts.count
  end

  test "cross-tenant and unrelated deployment evidence is rejected" do
    other_org = create_test_organization
    other_app = other_org.applications.create!(
      name: "Other", repository_full_name: "outside/unknown"
    )
    other_env = other_app.environments.create!(name: "production", kind: "production")
    other_artifact = other_app.artifacts.create!(
      kind: "image", identifier: "oci:outside", image_digest: "sha256:" + "d" * 64
    )
    foreign_deployment = other_env.deployments.create!(
      artifact: other_artifact, provider: "ci",
      external_id: "outside-deploy", deployed_at: Time.current, status: "reported"
    )

    login(@owner)
    post record_finding_remediation_path(@finding), params: {
      status: "reported_applied", description: "not our deployment",
      deployment_id: foreign_deployment.id
    }
    assert_response :not_found
    assert_empty @finding.remediation_attempts

    other_comparison = other_org.drift_comparisons.create!(
      application: other_app,
      baseline_environment: other_app.environments.create!(name: "staging", kind: "staging"),
      target_environment: other_env,
      mode: "reported", status: "same", compared_at: Time.current,
      result: { dimensions: { artifact: { status: "same" } } }
    )
    post verify_finding_path(@finding), params: { comparison_id: other_comparison.id }
    assert_response :not_found
    assert_empty @finding.finding_verification_checks
  end

  test "viewers may inspect remediation evidence but cannot submit or verify it" do
    login(@viewer)
    get finding_path(@finding)
    assert_response :success
    assert_select "form[action=?]", record_finding_remediation_path(@finding), count: 0
    assert_select "form[action=?]", verify_finding_path(@finding), count: 0

    post record_finding_remediation_path(@finding), params: {
      status: "planned", description: "I cannot change this"
    }
    assert_response :forbidden
    post verify_finding_path(@finding), params: { comparison_id: @initial.id }
    assert_response :forbidden
    assert_equal 0, @finding.finding_verification_checks.count
    assert_equal 0, @finding.remediation_attempts.count
  end

  test "read API is scoped to both environments and never calls verification authoritative" do
    login(@owner)
    record_applied_deployment
    patch finding_path(@finding), params: {
      status: "verification_pending", note: "Track candidate remediation"
    }
    assert_redirected_to finding_path(@finding)
    travel 2.minutes do
      compare_artifact(status: "same", compared_at: Time.current)
    end
    get "/api/v1/findings/#{@finding.id}/remediations", headers: bearer_headers(@reader)
    assert_response :success
    attempts = response.parsed_body.fetch("remediations")
    assert_equal 1, attempts.size
    assert_equal @deployment.id, attempts.first.fetch("deployment_id")

    get "/api/v1/findings/#{@finding.id}/verifications", headers: bearer_headers(@reader)
    assert_response :success
    assert_equal false, response.parsed_body.fetch("verifications").first.fetch("authoritative")
    assert_equal "candidate_clear", response.parsed_body.fetch("verifications").first.fetch("outcome")

    scoped = issue_test_token(
      organization: @organization, permissions: %w[read],
      environment_scopes: ["staging"], repository_scopes: ["acme/payments"]
    )
    get "/api/v1/findings/#{@finding.id}/remediations", headers: bearer_headers(scoped)
    assert_response :forbidden
    get "/api/v1/findings/#{@finding.id}/verifications", headers: bearer_headers(scoped)
    assert_response :forbidden

    another = create_test_organization
    token = issue_test_token(organization: another, permissions: %w[read])
    get "/api/v1/findings/#{@finding.id}/verifications", headers: bearer_headers(token)
    assert_response :not_found
  end

  test "changing must_match to allowed_to_differ is a waiver, not a verified fix" do
    initial_fingerprint = @organization.drift_comparisons.create!(
      application: @application, baseline_environment: @staging,
      target_environment: @production, mode: "configuration_fingerprints",
      status: "different", compared_at: 3.hours.ago,
      result: { dimensions: { environment_value_fingerprints: {
        status: "different", confidence: "complete", values_compared: true,
        comparisons: [{ name: "API_KEY", policy: "must_match",
          evaluation: "violation", value_relation: "different" }]
      } } }
    )
    finding = @organization.drift_findings.find_by!(
      category: "policy_violation", subject: "API_KEY"
    )
    login(@owner)
    post record_finding_remediation_path(finding), params: {
      status: "reported_applied", description: "Changed policy, but no runtime fix",
      deployment_id: @deployment.id
    }
    assert_redirected_to finding_path(finding)
    patch finding_path(finding), params: {
      status: "verification_pending", note: "Confirm policy change"
    }
    assert_redirected_to finding_path(finding)

    travel 2.minutes do
      newer = @organization.drift_comparisons.create!(
        application: @application, baseline_environment: @staging,
        target_environment: @production, mode: "configuration_fingerprints",
        status: "same", compared_at: Time.current,
        result: { dimensions: { environment_value_fingerprints: {
          status: "same", confidence: "complete", values_compared: true,
          unresolved_keys: [],
          comparisons: [{ name: "API_KEY", policy: "allowed_to_differ",
            evaluation: "compliant", value_relation: "different" }]
        } } }
      )
      check = finding.finding_verification_checks.find_by!(drift_comparison: newer)
      assert_equal "policy_changed", check.outcome
      assert_equal "policy_exception_changed", check.reason_code
      assert_equal false, check.authoritative
      assert_equal "verification_pending", finding.reload.status
      assert_equal initial_fingerprint.id, finding.latest_comparison_id
    end
  end

  private

  def login(user)
    post login_path, params: { email: user.email, password: "strong-password-for-tests" }
    assert_redirected_to root_path
  end

  def record_applied_deployment
    post record_finding_remediation_path(@finding), params: {
      status: "reported_applied",
      description: "Deploy fixed image to production and collect fresh evidence",
      deployment_id: @deployment.id,
      reference_url: "https://github.com/acme/payments/pull/11"
    }
    assert_redirected_to finding_path(@finding)
  end

  def compare_artifact(status:, compared_at:)
    dimensions = {
      "artifact" => {
        "status" => status,
        "baseline" => ["sha256:" + "b" * 64],
        "target" => [status == "same" ? "sha256:" + "b" * 64 : "sha256:" + "a" * 64]
      }
    }
    @organization.drift_comparisons.create!(
      application: @application, baseline_environment: @staging,
      target_environment: @production, mode: "reported", status: status,
      compared_at: compared_at,
      result: { "confidence" => "reported_only", "verified_runtime" => false,
        "target" => { "workloads" => @deployment ? [{
          "event_id" => @deployment.external_id,
          "artifact_identifier" => @artifact.image_digest,
          "recorded_at" => compared_at.utc.iso8601
        }] : [] },
        "dimensions" => dimensions }
    )
  end
end
