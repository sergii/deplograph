require "test_helper"

class FindingsDashboardTest < ActionDispatch::IntegrationTest
  setup do
    @organization = create_test_organization
    @application = @organization.applications.create!(
      name: "Payments", repository_full_name: "acme/payments"
    )
    @staging = @application.environments.create!(name: "staging", kind: "staging")
    @production = @application.environments.create!(name: "production", kind: "production")
    @owner = User.create!(email: "owner-findings@example.test", password: "very-strong-test-password")
    @viewer = User.create!(email: "viewer-findings@example.test", password: "very-strong-test-password")
    Membership.create!(user: @owner, organization: @organization, role: "owner")
    Membership.create!(user: @viewer, organization: @organization, role: "viewer")
    @first = compare
  end

  test "auto-materializes distinct evidence-backed findings and deduplicates future observations" do
    assert_equal 4, @organization.drift_findings.count
    advisory = @organization.drift_findings.find_by!(category: "security_advisory")
    assert_equal "p1", advisory.priority
    assert_equal "unknown", advisory.severity
    assert_equal "reported_only", advisory.evidence_quality
    assert_equal @first.id, advisory.latest_comparison_id
    assert_equal "detected", advisory.drift_finding_events.first.action
    assert_equal 1, advisory.drift_finding_events.count

    login(@owner)
    patch finding_path(advisory), params: {
      status: "investigating", assigned_to_id: @owner.id,
      next_action: "Inspect production SBOM and image", note: "Checking digest evidence",
      priority: "p1", severity: "unknown"
    }
    assert_redirected_to finding_path(advisory)
    assert_equal "investigating", advisory.reload.status
    assert_equal @owner.id, advisory.assigned_to_id
    assert_equal "Inspect production SBOM and image", advisory.next_action

    second = compare
    assert_equal 4, @organization.drift_findings.count
    assert_equal second.id, advisory.reload.latest_comparison_id
    assert_equal "investigating", advisory.status
    assert_equal 1, advisory.drift_finding_events.where(action: "observed").count
    assert_equal @first.compared_at, advisory.first_seen_at
  end

  test "drift dashboard and finding history are rendered from the logged-in tenant" do
    login(@owner)
    get drift_dashboard_path
    assert_response :success
    assert_select "h1", text: "Drift comparisons"
    assert_select "a[href=?]", drift_comparison_path(@first)
    assert_select "form[action=?]", create_browser_comparison_path

    get drift_comparison_path(@first)
    assert_response :success
    assert_select "h1", text: "acme/payments"
    assert_select "a[href^='/findings/']", minimum: 1

    get findings_path, params: { priority: "p1", status: "open" }
    assert_response :success
    assert_select "h1", text: "Findings"
    assert_select "a[href^='/findings/']", minimum: 1
    assert_select "a", text: /Advisory/

    finding = @organization.drift_findings.find_by!(category: "security_advisory")
    get finding_path(finding)
    assert_response :success
    assert_select "h2", text: "Audit trail"
    assert_select "form[action=?]", finding_path(finding)
  end

  test "viewers can inspect evidence but cannot triage or create comparisons" do
    login(@viewer)
    get findings_path
    assert_response :success
    finding = @organization.drift_findings.first
    get finding_path(finding)
    assert_response :success
    assert_select "form[action=?]", finding_path(finding), count: 0

    patch finding_path(finding), params: { status: "dismissed", note: "No" }
    assert_response :forbidden
    assert_equal "open", finding.reload.status

    post create_browser_comparison_path, params: {
      application_id: @application.id, baseline_environment: "staging",
      target_environment: "production", mode: "reported"
    }
    assert_response :forbidden
    assert_equal 1, @organization.drift_comparisons.count
  end

  test "manual resolution is blocked and dismissals require an explanation" do
    login(@owner)
    finding = @organization.drift_findings.first
    patch finding_path(finding), params: { status: "resolved", note: "I deployed v2" }
    assert_response :unprocessable_entity
    assert_equal "open", finding.reload.status

    patch finding_path(finding), params: { status: "dismissed" }
    assert_response :unprocessable_entity
    assert_equal "open", finding.reload.status

    patch finding_path(finding), params: {
      status: "verification_pending", note: "Patch deployed to staging, awaiting runtime confirmation"
    }
    assert_redirected_to finding_path(finding)
    assert_equal "verification_pending", finding.reload.status
    assert_nil finding.resolved_at
    assert_equal "status_changed", finding.drift_finding_events.order(:id).last.action
  end

  test "organization switching never exposes another tenant's comparisons or findings" do
    other_org = create_test_organization
    other_app = other_org.applications.create!(
      name: "Same repository", repository_full_name: "acme/payments"
    )
    stage = other_app.environments.create!(name: "staging", kind: "staging")
    prod = other_app.environments.create!(name: "production", kind: "production")
    other_comparison = other_org.drift_comparisons.create!(
      application: other_app, baseline_environment: stage, target_environment: prod,
      mode: "reported", status: "different", compared_at: Time.current,
      result: { dimensions: { artifact: { status: "different" } } }
    )
    other_finding = other_org.drift_findings.first
    assert other_finding

    login(@owner)
    get drift_comparison_path(other_comparison)
    assert_response :not_found
    get finding_path(other_finding)
    assert_response :not_found
    get findings_path
    assert_response :success
    assert_select "a[href=?]", finding_path(other_finding), count: 0
    assert_select "a[href=?]", finding_path(@organization.drift_findings.first), count: 1

    get drift_dashboard_path
    assert_response :success
    assert_select "a[href=?]", drift_comparison_path(other_comparison), count: 0
  end

  test "anonymous visitors are redirected to login for every browser findings route" do
    finding = @organization.drift_findings.first
    [findings_path, finding_path(finding), drift_dashboard_path, drift_comparison_path(@first)].each do |path|
      get path
      assert_redirected_to login_path
    end
  end

  private

  def login(user)
    post login_path, params: { email: user.email, password: "very-strong-test-password" }
    assert_redirected_to root_path
  end

  def compare
    @organization.drift_comparisons.create!(
      application: @application, baseline_environment: @staging,
      target_environment: @production, mode: "reported", status: "different",
      compared_at: Time.current, result: {
        "confidence" => "reported_only", "verified_runtime" => false,
        "dimensions" => {
          "release" => { "status" => "different", "baseline" => ["v2"], "target" => ["v1"] },
          "artifact" => { "status" => "different", "baseline" => ["sha256:bbbb"], "target" => ["sha256:aaaa"] },
          "dependencies" => {
            "status" => "different", "inventory_coverage" => "partial",
            "version_changed" => [{ "package" => "gem:rack", "baseline_versions" => ["3.2"],
              "target_versions" => ["3.1"] }]
          },
          "security" => { "status" => "different", "only_in_target" => ["GHSA-test-prod"],
            "only_in_baseline" => [] }
        }
      }
    )
  end
end
