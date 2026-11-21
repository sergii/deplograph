require "test_helper"
require "openssl"
require "base64"

class TrustedRuntimeAttestationsTest < ActionDispatch::IntegrationTest
  DIGEST = "sha256:" + "b" * 64
  OLD_DIGEST = "sha256:" + "a" * 64

  setup do
    @organization = create_test_organization
    @application = @organization.applications.create!(
      name: "Payments", repository_full_name: "acme/payments"
    )
    @staging = @application.environments.create!(name: "staging", kind: "staging")
    @production = @application.environments.create!(name: "production", kind: "production")
    @owner = User.create!(email: "attestor-owner@example.test",
      password: "attestor-test-password")
    @viewer = User.create!(email: "attestor-viewer@example.test",
      password: "attestor-test-password")
    Membership.create!(user: @owner, organization: @organization, role: "owner")
    Membership.create!(user: @viewer, organization: @organization, role: "viewer")
    @credential, @token = IntegrationCredential.issue!(
      organization: @organization, provider: "kubernetes",
      name: "Production control-plane", permissions: %w[observe],
      repository_scopes: ["acme/payments"], environment_scopes: ["production"]
    )
    @key = OpenSSL::PKey.generate_key("ED25519")
    @attestor = @organization.runtime_attestors.create!(
      application: @application, environment: @production,
      integration_credential: @credential, approved_by: @owner,
      name: "production-k8s", image_repository: "ghcr.io/acme/payments",
      expected_workloads: { "web" => 2, "worker" => 1 },
      public_key_pem: @key.public_to_pem, resolution_enabled: true
    )
    @original = comparison("different", compared_at: 3.hours.ago,
      target_digest: OLD_DIGEST)
    @finding = @organization.drift_findings.find_by!(category: "artifact_drift")
    @artifact = @application.artifacts.create!(
      kind: "image", image_digest: DIGEST,
      identifier: "oci:ghcr.io/acme/payments@#{DIGEST}"
    )
    @deployment = @production.deployments.create!(
      artifact: @artifact, provider: "github_actions", status: "reported",
      external_id: "deploy-fixed", deployed_at: 30.minutes.ago
    )
  end

  test "signed full-coverage control-plane evidence closes only eligible artifact drift" do
    stage_candidate
    travel 3.seconds do
      result = submit_attestation
      assert_response :created
      assert_equal true, result.fetch("signature_verified")
      assert_equal true, result.fetch("complete")
      assert_equal 3, result.fetch("ready_replicas")
      assert_equal 1, result.fetch("resolutions").size
      assert_equal 1, RuntimeAttestation.count
      assert_equal "resolved", @finding.reload.status
      assert_equal "verified", @finding.evidence_quality
      assert @finding.resolved_at
      assert_equal 1, @finding.finding_resolutions.count
      assert_equal 1, @finding.drift_finding_events.where(action: "verified_resolution").count
      assert_equal "candidate_clear", @finding.finding_verification_checks.first.outcome
      assert_equal false, @finding.finding_verification_checks.first.authoritative
      evidence = @finding.finding_resolutions.first
      assert_equal @deployment.id, evidence.remediation_attempt.deployment_id
      assert_equal @attestor.id, evidence.runtime_attestation.runtime_attestor_id
    end
  end

  test "incomplete coverage is accepted as evidence but can never resolve finding" do
    stage_candidate
    travel 3.seconds do
      signed = full_assertion
      signed["workloads"].first["replicas"].pop
      signed["workloads"].first["ready_replicas"] = 1
      result = submit_attestation(assertion: signed)
      assert_response :created
      assert_equal false, result.fetch("complete")
      assert_empty result.fetch("resolutions")
      assert_equal "verification_pending", @finding.reload.status
      assert_equal 0, FindingResolution.count
    end
  end

  test "signed digest mismatch is not sufficient even with full replica readiness" do
    stage_candidate
    travel 3.seconds do
      signed = full_assertion
      signed["image_digest"] = OLD_DIGEST
      signed["workloads"].each do |workload|
        workload["replicas"].each { |replica| replica["image_digest"] = OLD_DIGEST }
      end
      result = submit_attestation(assertion: signed)
      assert_response :created
      assert_equal true, result.fetch("complete")
      assert_empty result.fetch("resolutions")
      assert_equal "verification_pending", @finding.reload.status
    end
  end

  test "wrong signature is rejected without consuming the challenge" do
    stage_candidate
    travel 3.seconds do
      challenge = new_challenge
      assertion = full_assertion.merge("nonce" => challenge.fetch("nonce"))
      other_key = OpenSSL::PKey.generate_key("ED25519")
      post_signature(assertion, Base64.strict_encode64(
        other_key.sign(nil, Runtime::AttestationProtocol.canonical_json(assertion))
      ))
      assert_response :unprocessable_entity
      assert_equal 0, RuntimeAttestation.count
      assert_nil RuntimeAttestationChallenge.find_by!(nonce: challenge.fetch("nonce")).consumed_at

      post_signature(assertion, sign(assertion))
      assert_response :created
      assert_equal 1, RuntimeAttestation.count
      assert_equal "resolved", @finding.reload.status
    end
  end

  test "replaying a consumed nonce fails even with a valid signature" do
    stage_candidate
    travel 3.seconds do
      challenge = new_challenge
      assertion = full_assertion.merge("nonce" => challenge.fetch("nonce"))
      signature = sign(assertion)
      2.times do |iteration|
        post_signature(assertion, signature)
        assert_response iteration.zero? ? :created : :conflict
      end
      assert_equal 1, RuntimeAttestation.count
      assert_equal 1, FindingResolution.count
    end
  end

  test "expired nonce and stale signed observations do not establish runtime state" do
    stage_candidate
    challenge = new_challenge
    RuntimeAttestationChallenge.find_by!(nonce: challenge.fetch("nonce"))
      .update!(expires_at: 1.minute.ago)
    assertion = full_assertion.merge("nonce" => challenge.fetch("nonce"))
    post_signature(assertion, sign(assertion))
    assert_response :conflict
    assert_equal 0, RuntimeAttestation.count

    challenge = new_challenge
    signed = full_assertion.merge("nonce" => challenge.fetch("nonce"),
      "observed_at" => 5.minutes.ago.utc.iso8601)
    post_signature(signed, sign(signed))
    assert_response :unprocessable_entity
    assert_equal "verification_pending", @finding.reload.status
  end

  test "revoked attestors and unrelated providers cannot issue challenges" do
    other = issue_test_token(organization: @organization, provider: "kubernetes",
      permissions: %w[observe], repository_scopes: ["acme/payments"],
      environment_scopes: ["production"])
    post "/api/v1/runtime/attestation_challenges",
      params: JSON.generate(attestor_id: @attestor.id), headers: bearer_headers(other)
    assert_response :forbidden

    @attestor.update!(revoked_at: Time.current)
    post "/api/v1/runtime/attestation_challenges",
      params: JSON.generate(attestor_id: @attestor.id), headers: bearer_headers(@token)
    assert_response :forbidden
    assert_equal 0, RuntimeAttestationChallenge.count
  end

  test "disabled resolution remains observation-only and cannot close finding" do
    stage_candidate
    @attestor.update!(resolution_enabled: false)
    travel 3.seconds do
      result = submit_attestation
      assert_response :created
      assert_equal true, result.fetch("complete")
      assert_empty result.fetch("resolutions")
      assert_equal "verification_pending", @finding.reload.status
    end
  end

  test "signed assertions never auto-resolve unrelated security or configuration findings" do
    stage_candidate
    @organization.drift_comparisons.create!(
      application: @application, baseline_environment: @staging,
      target_environment: @production, mode: "configuration_fingerprints",
      status: "different", compared_at: 2.hours.ago,
      result: { "dimensions" => { "environment_value_fingerprints" => {
        "status" => "different", "comparisons" => [
          { "name" => "SECRET_KEY", "evaluation" => "violation", "policy" => "must_match" }
        ]
      } } }
    )
    policy_finding = @organization.drift_findings.find_by!(category: "policy_violation")
    policy_finding.update!(status: "verification_pending")

    travel 3.seconds do
      submit_attestation
      assert_response :created
      assert_equal "verification_pending", policy_finding.reload.status
      assert_nil policy_finding.resolved_at
      assert_equal 0, policy_finding.finding_resolutions.count
    end
  end

  test "new artifact regression reopens resolved finding while preserving resolution history" do
    stage_candidate
    travel 3.seconds do
      submit_attestation
      assert_equal "resolved", @finding.reload.status
    end
    travel 8.seconds do
      regression = comparison("different", compared_at: Time.current,
        target_digest: OLD_DIGEST)
      assert_equal "open", @finding.reload.status
      assert_nil @finding.resolved_at
      assert_equal regression.id, @finding.latest_comparison_id
      assert_equal 1, FindingResolution.where(drift_finding: @finding).count
      assert_equal 1, @finding.drift_finding_events.where(action: "reopened").count
    end
  end

  test "owner can enroll a new public key but cannot bind it to a foreign tenant environment" do
    login(@owner)
    post runtime_attestors_path, params: {
      application_id: @application.id,
      environment_id: @production.id,
      integration_credential_id: @credential.id,
      name: "production-k8s-backup",
      image_repository: "ghcr.io/acme/payments",
      expected_workloads: '{"web":2,"worker":1}',
      public_key_pem: OpenSSL::PKey.generate_key("ED25519").public_to_pem,
      resolution_enabled: "0"
    }
    assert_redirected_to runtime_attestors_path
    backup = @organization.runtime_attestors.find_by!(name: "production-k8s-backup")
    assert_equal false, backup.resolution_enabled
    assert_equal @owner.id, backup.approved_by_id

    foreign_org = create_test_organization
    foreign_app = foreign_org.applications.create!(
      name: "Other", repository_full_name: "other/other"
    )
    foreign_env = foreign_app.environments.create!(
      name: "production", kind: "production"
    )
    post runtime_attestors_path, params: {
      application_id: @application.id,
      environment_id: foreign_env.id,
      integration_credential_id: @credential.id,
      name: "injected",
      image_repository: "ghcr.io/acme/payments",
      expected_workloads: '{"web":2}',
      public_key_pem: @key.public_to_pem,
      resolution_enabled: "1"
    }
    assert_response :not_found
    assert_equal 2, @organization.runtime_attestors.count
  end

  test "owner can enroll and revoke but viewer cannot and private key input is refused" do
    login(@viewer)
    get runtime_attestors_path
    assert_response :success
    assert_select "h1", text: "Kubernetes attestors"
    assert_select "form[action=?]", runtime_attestors_path, count: 0
    post revoke_runtime_attestor_path(@attestor)
    assert_response :forbidden

    login(@owner)
    get runtime_attestors_path
    assert_response :success
    assert_select "form[action=?]", runtime_attestors_path
    post runtime_attestors_path, params: {
      application_id: @application.id, environment_id: @production.id,
      integration_credential_id: @credential.id, name: "bad-private-key",
      image_repository: "ghcr.io/acme/payments",
      expected_workloads: '{"web":2,"worker":1}',
      public_key_pem: @key.private_to_pem, resolution_enabled: "1"
    }
    assert_response :unprocessable_entity

    post revoke_runtime_attestor_path(@attestor)
    assert_redirected_to runtime_attestors_path
    assert @attestor.reload.revoked_at
  end

  private

  def login(user)
    post login_path, params: {
      email: user.email, password: "attestor-test-password"
    }
    assert_redirected_to root_path
  end

  def stage_candidate
    @attempt = @finding.remediation_attempts.create!(
      created_by: @owner, description: "Fixed image deployed to production",
      status: "reported_applied", deployment: @deployment
    )
    @finding.update!(status: "verification_pending")
    travel 2.seconds do
      @candidate = comparison("same", compared_at: Time.current, target_digest: DIGEST)
    end
    check = @finding.finding_verification_checks.find_by!(drift_comparison: @candidate)
    assert_equal "candidate_clear", check.outcome
    assert_equal "verification_pending", @finding.reload.status
  end

  def comparison(state, compared_at:, target_digest:)
    @organization.drift_comparisons.create!(
      application: @application,
      baseline_environment: @staging, target_environment: @production,
      mode: "reported", status: state, compared_at: compared_at,
      result: {
        "confidence" => "reported_only", "verified_runtime" => false,
        "target" => { "workloads" => [
          { "event_id" => "deploy-fixed",
            "artifact_identifier" => target_digest,
            "recorded_at" => compared_at.utc.iso8601 }
        ] },
        "dimensions" => {
          "artifact" => {
            "status" => state, "baseline" => [DIGEST], "target" => [target_digest]
          }
        }
      }
    )
  end

  def new_challenge
    post "/api/v1/runtime/attestation_challenges",
      params: JSON.generate(attestor_id: @attestor.id), headers: bearer_headers(@token)
    assert_response :created
    response.parsed_body
  end

  def full_assertion
    workloads = @attestor.expected_workloads.sort.map do |name, count|
      {
        "name" => name, "desired_replicas" => count,
        "ready_replicas" => count,
        "replicas" => (1..count).map do |n|
          { "uid" => "#{name}-pod-#{n}", "ready" => true, "image_digest" => DIGEST }
        end
      }
    end
    {
      "version" => 1, "nonce" => "not-set",
      "attestor_id" => @attestor.id,
      "observation_id" => SecureRandom.uuid,
      "repository" => "acme/payments", "environment" => "production",
      "image_repository" => "ghcr.io/acme/payments",
      "image_digest" => DIGEST, "observed_at" => Time.current.utc.iso8601,
      "workloads" => workloads
    }
  end

  def sign(assertion)
    Base64.strict_encode64(
      @key.sign(nil, Runtime::AttestationProtocol.canonical_json(assertion))
    )
  end

  def post_signature(assertion, signature)
    post "/api/v1/runtime/attestations",
      params: JSON.generate({
        attestor_id: @attestor.id, attestation: assertion, signature: signature
      }), headers: bearer_headers(@token)
  end

  def submit_attestation(assertion: full_assertion)
    challenge = new_challenge
    assertion["nonce"] = challenge.fetch("nonce")
    post_signature(assertion, sign(assertion))
    response.parsed_body
  end
end
