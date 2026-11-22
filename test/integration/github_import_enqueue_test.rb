require "test_helper"

class GithubImportEnqueueTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @organization = create_test_organization
    @owner = User.create!(email: "pilot-owner@example.test",
      password: "pilot-strong-password")
    Membership.create!(organization: @organization, user: @owner, role: "owner")
    @installation = GithubInstallation.create!(
      organization: @organization, installation_id: 87654,
      account_id: 222, account_login: "pilot-org",
      state: "active", permissions: { "contents" => "read" }
    )
    @grant = @installation.github_repository_grants.create!(
      github_repository_id: 98765, full_name: "pilot-org/rails-app", enabled: true
    )
    post login_path, params: {
      email: @owner.email, password: "pilot-strong-password"
    }
    assert_redirected_to root_path
  end

  test "owner queues import without making a synchronous GitHub API request" do
    assert_enqueued_with(job: Github::SyncRepositoryJob, args: [{
      installation_id: 87654, repository_id: 98765
    }]) do
      post import_github_repository_path(87654, 98765),
        headers: { "ACCEPT" => "application/json" }
    end
    assert_response :accepted
    assert_equal "queued", response.parsed_body.fetch("status")
    assert_equal "pending", @grant.reload.sbom_sync_status
    assert_equal 0, InventorySnapshot.count
  end

  test "viewer cannot trigger repository imports" do
    Membership.find_by!(organization: @organization, user: @owner)
      .update!(role: "viewer")
    assert_no_enqueued_jobs do
      post import_github_repository_path(87654, 98765)
    end
    assert_response :forbidden
    assert_equal "not_requested", @grant.reload.sbom_sync_status
  end

  test "suspended installation cannot queue new imports" do
    @installation.update!(state: "suspended")
    assert_no_enqueued_jobs do
      post import_github_repository_path(87654, 98765)
    end
    assert_response :forbidden
    assert_equal "not_requested", @grant.reload.sbom_sync_status
  end
end
