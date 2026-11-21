require "test_helper"
require "openssl"
require "uri"

class GithubAppConnectTest < ActionDispatch::IntegrationTest
  setup do
    @previous = %w[
      GITHUB_APP_ID GITHUB_APP_CLIENT_ID GITHUB_APP_CLIENT_SECRET
      GITHUB_APP_PRIVATE_KEY GITHUB_APP_CALLBACK_URL
    ].to_h { |key| [key, ENV[key]] }
    ENV["GITHUB_APP_ID"] = "1234"
    ENV["GITHUB_APP_CLIENT_ID"] = "Iv1.test"
    ENV["GITHUB_APP_CLIENT_SECRET"] = "test-secret"
    ENV["GITHUB_APP_PRIVATE_KEY"] = OpenSSL::PKey::RSA.generate(2048).to_pem
    ENV["GITHUB_APP_CALLBACK_URL"] = "https://deplograph.example/github/installations/callback"

    @organization = create_test_organization(slug: "integration-owner")
    @user = User.create!(email: "owner@example.test", password: "long-test-password")
    Membership.create!(user: @user, organization: @organization, role: "owner")
    post login_path, params: { email: @user.email, password: "long-test-password" }
    assert_redirected_to root_path
  end

  teardown do
    @previous.each { |key, value| ENV[key] = value }
  end

  test "only verified GitHub user installations can be linked to a tenant" do
    stub_github_authorization([authorized_installation(987)])
    stub_app_installation(987)
    stub_installation_repositories(987, [
      { id: 7654, full_name: "private-org/private-repo", private: true }
    ])

    state = authorize_setup(987)
    get github_installation_callback_path, params: { state: state, code: "one-time-code" }
    assert_redirected_to github_installations_path

    installation = GithubInstallation.find_by!(installation_id: 987)
    assert_equal @organization.id, installation.organization_id
    assert_equal @user.id, installation.linked_by_id
    assert_equal "active", installation.state
    assert_equal 1, installation.github_repository_grants.where(enabled: true).count
    assert_equal "private-org/private-repo", installation.github_repository_grants.first.full_name
  end

  test "a spoofed installation ID cannot be linked even with a valid OAuth token" do
    stub_github_authorization([authorized_installation(987)])
    state = authorize_setup(12345)
    get github_installation_callback_path, params: { state: state, code: "one-time-code" }

    assert_response :forbidden
    assert_equal 0, GithubInstallation.where(organization: @organization).count
  end

  test "OAuth state is required and cannot be replayed" do
    state = authorize_setup(987)
    get github_installation_callback_path, params: { state: "wrong-state", code: "fake" }
    assert_response :forbidden
    get github_installation_callback_path, params: { state: state, code: "fake" }
    assert_response :forbidden
    assert_equal 0, GithubInstallation.count
  end

  test "read-only organization membership cannot connect installations" do
    @user.memberships.first.update!(role: "viewer")
    post authorize_github_installation_path, params: { installation_id: 987 }
    assert_response :forbidden
  end

  test "already claimed installation is not transferable to another organization" do
    other = create_test_organization(slug: "another-org")
    Membership.create!(user: @user, organization: other, role: "owner")
    GithubInstallation.create!(installation_id: 987, organization: other,
      account_login: "private-org", account_id: 42, permissions: { contents: "read" })

    stub_github_authorization([authorized_installation(987)])
    stub_app_installation(987)
    stub_installation_repositories(987, [
      { id: 7654, full_name: "private-org/private-repo", private: true }
    ])
    state = authorize_setup(987)
    get github_installation_callback_path, params: { state: state, code: "one-time-code" }
    assert_response :conflict

    assert_equal other.id, GithubInstallation.find_by!(installation_id: 987).organization_id
  end

  test "GitHub setup URL does not grant access without authorization" do
    get github_installation_setup_path, params: { installation_id: 987 }
    assert_response :success
    assert_equal 0, GithubInstallation.where(organization: @organization).count
  end

  private

  def authorize_setup(id)
    post authorize_github_installation_path, params: { installation_id: id }
    assert_response :redirect
    uri = URI.parse(response.location)
    assert_equal "github.com", uri.host
    assert_equal "/login/oauth/authorize", uri.path
    state = URI.decode_www_form(uri.query).to_h.fetch("state")
    assert state.length >= 32
    state
  end

  def authorized_installation(id)
    { id: id, app_id: 1234 }
  end

  def stub_github_authorization(installations)
    stub_request(:post, "https://github.com/login/oauth/access_token")
      .to_return(status: 200, body: JSON.generate(access_token: "ghu-test-user-token"))
    stub_request(:get, "https://api.github.com/user/installations?per_page=100&page=1")
      .with(headers: { "Authorization" => "Bearer ghu-test-user-token" })
      .to_return(status: 200, body: JSON.generate(installations: installations))
  end

  def stub_app_installation(id)
    stub_request(:get, "https://api.github.com/app/installations/#{id}")
      .to_return(status: 200, body: JSON.generate(
        id: id, app_id: 1234, permissions: { contents: "read", metadata: "read" },
        suspended_at: nil, account: { id: 42, login: "private-org" }
      ))
  end

  def stub_installation_repositories(id, repos)
    stub_request(:post, "https://api.github.com/app/installations/#{id}/access_tokens")
      .to_return(status: 201, body: JSON.generate(token: "ghs-test-installation-token"))
    stub_request(:get, "https://api.github.com/installation/repositories?per_page=100&page=1")
      .with(headers: { "Authorization" => "Bearer ghs-test-installation-token" })
      .to_return(status: 200, body: JSON.generate(repositories: repos))
  end
end
