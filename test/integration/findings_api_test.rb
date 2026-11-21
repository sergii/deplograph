require "test_helper"

class FindingsApiTest < ActionDispatch::IntegrationTest
  setup do
    @organization = create_test_organization
    @application = @organization.applications.create!(
      name: "Payments", repository_full_name: "acme/payments"
    )
    @staging = @application.environments.create!(name: "staging", kind: "staging")
    @production = @application.environments.create!(name: "production", kind: "production")
    @comparison = @organization.drift_comparisons.create!(
      application: @application, baseline_environment: @staging,
      target_environment: @production, mode: "configuration_fingerprints",
      status: "different", compared_at: Time.current,
      result: { "dimensions" => { "environment_value_fingerprints" => {
        "status" => "different", "confidence" => "partial",
        "comparisons" => [
          { "name" => "API_KEY", "evaluation" => "violation",
            "policy" => "must_match", "value_relation" => "different" },
          { "name" => "DATABASE_URL", "evaluation" => "compliant",
            "policy" => "allowed_to_differ", "value_relation" => "different" },
          { "name" => "INCOMPLETE", "evaluation" => "unknown",
            "policy" => "must_match", "value_relation" => "unknown" }
        ]
      } } }
    )
    @finding = @organization.drift_findings.find_by!(category: "policy_violation")
    @reader = issue_test_token(organization: @organization, permissions: %w[read],
      repository_scopes: ["acme/payments"])
  end

  test "only actionable rule violations become findings, not expected differences" do
    assert_equal 2, @organization.drift_findings.count
    assert_equal %w[fingerprint_gap policy_violation],
      @organization.drift_findings.pluck(:category).sort
    assert_equal "API_KEY", @finding.subject
    assert_equal "partial", @finding.evidence_quality
    assert_equal @comparison.id, @finding.latest_comparison_id
    assert_nil @finding.resolved_at
  end

  test "read-only API lists and shows findings with both environment scope checks" do
    get "/api/v1/findings", headers: bearer_headers(@reader)
    assert_response :success
    assert_equal 2, response.parsed_body.fetch("findings").size

    get "/api/v1/findings/#{@finding.id}", headers: bearer_headers(@reader)
    assert_response :success
    assert_equal "API_KEY", response.parsed_body.fetch("subject")
    refute_includes response.body, "fingerprints_sha256"
    refute_includes response.body, "digest"

    limited = issue_test_token(organization: @organization, permissions: %w[read],
      repository_scopes: ["acme/payments"], environment_scopes: ["staging"])
    get "/api/v1/findings", headers: bearer_headers(limited)
    assert_response :success
    assert_empty response.parsed_body.fetch("findings")

    get "/api/v1/findings/#{@finding.id}", headers: bearer_headers(limited)
    assert_response :forbidden

    other = create_test_organization
    token = issue_test_token(organization: other, permissions: %w[read])
    get "/api/v1/findings/#{@finding.id}", headers: bearer_headers(token)
    assert_response :not_found
  end

  test "unscanned evidence creates visible warning findings instead of a safe result" do
    comparison = @organization.drift_comparisons.create!(
      application: @application, baseline_environment: @staging,
      target_environment: @production,
      mode: "observed", status: "unknown", compared_at: Time.current,
      result: { "dimensions" => {
        "security" => { "status" => "unknown", "reason" => "Missing scans" },
        "artifact" => { "status" => "stale", "reason" => "Old observation" }
      } }
    )
    gaps = @organization.drift_findings.where(latest_comparison_id: comparison.id)
    assert_equal 2, gaps.count
    assert_equal %w[stale unknown], gaps.pluck(:evidence_quality).sort
    assert_equal %w[p3], gaps.pluck(:priority).uniq
    assert_equal 0, gaps.where(status: "resolved").count
  end
end
