require "test_helper"
require "openssl"

class GithubPrivateRepositoryTest < ActionDispatch::IntegrationTest
  setup do
    @prior = %w[GITHUB_APP_ID GITHUB_APP_PRIVATE_KEY GITHUB_TOKEN].to_h { |key| [key, ENV[key]] }
    ENV["GITHUB_APP_ID"] = "1234"
    ENV["GITHUB_APP_PRIVATE_KEY"] = OpenSSL::PKey::RSA.generate(2048).to_pem
    ENV["GITHUB_TOKEN"] = "SHARED-TOKEN-MUST-NOT-BE-USED"
    @org = create_test_organization
    @token = issue_test_token(organization: @org, provider: "api", permissions: %w[read])
    @other_org = create_test_organization
    @other_token = issue_test_token(organization: @other_org, provider: "api", permissions: %w[read])

    @installation = GithubInstallation.create!(
      organization: @org, installation_id: 987,
      account_id: 42, account_login: "private-org",
      permissions: { contents: "read" }, state: "active"
    )
    @installation.github_repository_grants.create!(
      github_repository_id: 7654, full_name: "private-org/private-repo", enabled: true
    )

    stub_request(:get, "https://api.github.com/app/installations/987")
      .to_return(status: 200, body: JSON.generate(
        id: 987, app_id: 1234, permissions: { contents: "read" }, suspended_at: nil
      ))
    token_request = stub_request(:post, "https://api.github.com/app/installations/987/access_tokens")
      .with { |req| JSON.parse(req.body).fetch("repository_ids") == [7654] }
      .to_return(status: 201, body: JSON.generate(token: "ghs-one-repository-only"))
    @token_request = token_request

    stub_request(:get, "https://api.github.com/repos/private-org/private-repo")
      .with(headers: { "Authorization" => "Bearer ghs-one-repository-only" })
      .to_return(status: 200, body: JSON.generate(
        full_name: "private-org/private-repo", private: true, default_branch: "main"
      ))
    stub_request(:get, %r{\Ahttps://api\.github\.com/repos/private-org/private-repo/contents/})
      .with(headers: { "Authorization" => "Bearer ghs-one-repository-only" })
      .to_return(status: 404, body: '{"message":"Not Found"}')
  end

  teardown do
    @prior.each { |name, value| ENV[name] = value }
  end

  test "private repository is inspected with a one-repository installation token" do
    post "/api/v1/repositories/inspect",
      params: JSON.generate(repository: "private-org/private-repo"),
      headers: bearer_headers(@token)
    assert_response :success
    assert_equal true, response.parsed_body.fetch("private")
    assert_requested @token_request
    assert_equal 1, @org.applications.count
  end

  test "another organization cannot reuse an installation or its short-lived token" do
    public_lookup = stub_request(:get, "https://api.github.com/repos/private-org/private-repo")
      .with { |req| req.headers["Authorization"].nil? }
      .to_return(status: 404, body: '{"message":"Not Found"}')

    post "/api/v1/repositories/inspect",
      params: JSON.generate(repository: "private-org/private-repo"),
      headers: bearer_headers(@other_token)
    assert_response :bad_gateway
    assert_requested public_lookup
    assert_not_requested @token_request
    assert_equal 0, @other_org.applications.first.artifacts.count
  end
end
