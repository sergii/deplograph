require "test_helper"
require "base64"
require "openssl"

module Github
  class LockfileCollectorTest < ActiveSupport::TestCase
    setup do
      @before = %w[GITHUB_APP_ID GITHUB_APP_PRIVATE_KEY].to_h { |k| [k, ENV[k]] }
      ENV["GITHUB_APP_ID"] = "1234"
      ENV["GITHUB_APP_PRIVATE_KEY"] = OpenSSL::PKey::RSA.generate(2048).to_pem

      @org = create_test_organization
      @installation = GithubInstallation.create!(
        organization: @org, installation_id: 987, account_login: "acme",
        account_id: 42, permissions: { contents: "read" }, state: "active"
      )
      @grant = @installation.github_repository_grants.create!(
        github_repository_id: 700, full_name: "acme/ruby-demo", enabled: true
      )
    end

    teardown do
      @before.each { |key, value| ENV[key] = value }
    end

    test "collects Gemfile.lock via a one-repository GitHub App installation token" do
      stub_request(:get, "https://api.github.com/app/installations/987")
        .to_return(status: 200, body: JSON.generate(
          id: 987, app_id: 1234, permissions: { contents: "read" }, suspended_at: nil
        ))
      token_call = stub_request(:post, "https://api.github.com/app/installations/987/access_tokens")
        .with { |request| JSON.parse(request.body).fetch("repository_ids") == [700] }
        .to_return(status: 201, body: JSON.generate(token: "ghs-one-repository-token"))
      stub_request(:get, "https://api.github.com/repos/acme/ruby-demo")
        .with(headers: { "Authorization" => "Bearer ghs-one-repository-token" })
        .to_return(status: 200, body: JSON.generate(id: 700, default_branch: "main"))
      content = File.read(Rails.root.join("examples/scenarios/rails-lockfile/Gemfile.lock"))
      stub_request(:get, "https://api.github.com/repos/acme/ruby-demo/contents/Gemfile.lock?ref=main")
        .with(headers: { "Authorization" => "Bearer ghs-one-repository-token" })
        .to_return(status: 200, body: JSON.generate(
          type: "file", size: content.bytesize,
          content: Base64.strict_encode64(content)
        ))

      snapshot = LockfileCollector.new.call(grant: @grant)
      assert_equal "github-lockfile", snapshot.source
      assert_equal 3, snapshot.component_occurrences.count
      assert_equal @org.id, snapshot.artifact.application.organization_id
      assert_equal "partial", snapshot.coverage_status
      assert_nil snapshot.artifact.commit_sha
      assert_requested token_call
    end

    test "revoked grant fails without creating an inventory" do
      @grant.update!(enabled: false)
      assert_raises(LockfileCollector::PermissionError) do
        LockfileCollector.new.call(grant: @grant)
      end
      assert_equal 0, InventorySnapshot.count
    end
  end
end
