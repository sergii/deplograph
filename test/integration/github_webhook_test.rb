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

  test "duplicate delivery is idempotent and different body with same delivery ID is rejected" do
    id = SecureRandom.uuid
    payload = { action: "created", installation: @installation, repositories: [@repository] }
    deliver("installation", payload, delivery_id: id)
    deliver("installation", payload, delivery_id: id)
    assert_equal 1, GithubWebhookDelivery.where(delivery_id: id).count
    assert_equal 1, GithubInstallation.count

    altered = payload.merge(action: "deleted")
    json = JSON.generate(altered)
    signature = OpenSSL::HMAC.hexdigest("SHA256", ENV.fetch("GITHUB_WEBHOOK_SECRET"), json)
    post "/api/v1/github/webhooks", params: json,
      headers: { "CONTENT_TYPE" => "application/json",
                 "X-GitHub-Event" => "installation",
                 "X-GitHub-Delivery" => id,
                 "X-Hub-Signature-256" => "sha256=#{signature}" }
    assert_response :unprocessable_entity
    assert_equal "active", GithubInstallation.last.state
  end

  test "deleted installation is not reactivated by late created event" do
    deliver("installation", action: "created", installation: @installation, repositories: [@repository])
    deliver("installation", action: "deleted", installation: @installation)
    deliver("installation", action: "created", installation: @installation, repositories: [@repository])

    assert_equal "deleted", GithubInstallation.last.state
    assert_not GithubRepositoryGrant.last.enabled?
  end

  test "push only queues sync for a linked active and granted installation" do
    org = create_test_organization
    record = GithubInstallation.create!(
      organization: org, installation_id: 999,
      account_id: 999, account_login: "acme",
      permissions: { "contents" => "read" }
    )
    record.github_repository_grants.create!(
      github_repository_id: 4567, full_name: "acme/rails-app", enabled: true
    )
    payload = {
      installation: { id: 999 },
      repository: { id: 4567, full_name: "acme/rails-app" }
    }

    assert_enqueued_with(job: Github::SyncRepositoryJob) do
      deliver("push", payload)
    end

    record.github_repository_grants.first.update!(enabled: false)
    assert_no_enqueued_jobs do
      deliver("push", payload)
    end
  end

  private

  def deliver(event, body = nil, delivery_id: SecureRandom.uuid, **attributes)
    json = JSON.generate(body || attributes)
    signature = OpenSSL::HMAC.hexdigest("SHA256", ENV.fetch("GITHUB_WEBHOOK_SECRET"), json)
    post "/api/v1/github/webhooks", params: json,
      headers: { "CONTENT_TYPE" => "application/json",
                 "X-GitHub-Event" => event,
                 "X-GitHub-Delivery" => delivery_id,
                 "X-Hub-Signature-256" => "sha256=#{signature}" }
    assert_response :accepted, response.body
  end
end
