require "test_helper"
require "openssl"

class GithubWebhookTest < ActionDispatch::IntegrationTest
  setup do
    @prior = ENV["GITHUB_WEBHOOK_SECRET"]
    ENV["GITHUB_WEBHOOK_SECRET"] = "test-github-hook-secret"
    @installation = { id: 123456, account: { id: 999, login: "acme" },
                      permissions: { contents: "read", metadata: "read" } }
    @repository = { id: 4567, full_name: "acme/rails-app" }
  end

  teardown do
    ENV["GITHUB_WEBHOOK_SECRET"] = @prior
  end

  test "rejects invalid signatures" do
    post "/api/v1/github/webhooks",
      params: JSON.generate(action: "created", installation: @installation),
      headers: { "CONTENT_TYPE" => "application/json",
                 "X-GitHub-Event" => "installation",
                 "X-Hub-Signature-256" => "sha256=invalid" }
    assert_response :unauthorized
    assert_equal 0, GithubInstallation.count
  end

  test "tracks installation, permission withdrawal and deletion" do
    deliver("installation", action: "created", installation: @installation,
      repositories: [@repository])
    installation = GithubInstallation.find_by!(installation_id: 123456)
    assert_equal "active", installation.state
    assert_equal "read", installation.permissions.fetch("contents")
    assert installation.github_repository_grants.first.enabled?

    deliver("installation_repositories", action: "removed",
      installation: @installation,
      repositories_added: [], repositories_removed: [@repository])
    assert_not installation.github_repository_grants.first.reload.enabled?

    deliver("installation", action: "deleted", installation: @installation)
    assert_equal "deleted", installation.reload.state
    assert_not installation.github_repository_grants.first.reload.enabled?
  end

  private

  def deliver(event, body)
    json = JSON.generate(body)
    signature = OpenSSL::HMAC.hexdigest("SHA256", ENV.fetch("GITHUB_WEBHOOK_SECRET"), json)
    post "/api/v1/github/webhooks", params: json,
      headers: { "CONTENT_TYPE" => "application/json",
                 "X-GitHub-Event" => event,
                 "X-Hub-Signature-256" => "sha256=#{signature}" }
    assert_response :accepted, response.body
  end
end
