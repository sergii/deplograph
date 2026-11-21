require "test_helper"
require "openssl"

class GithubSbomImporterTest < ActiveSupport::TestCase
  setup do
    @prior = %w[GITHUB_APP_ID GITHUB_APP_PRIVATE_KEY].to_h { |name| [name, ENV[name]] }
    ENV["GITHUB_APP_ID"] = "1234"
    ENV["GITHUB_APP_PRIVATE_KEY"] = OpenSSL::PKey::RSA.generate(2048).to_pem
    @organization = create_test_organization
    @installation = GithubInstallation.create!(
      organization: @organization, installation_id: 987,
      account_id: 42, account_login: "private-org",
      state: "active", permissions: { contents: "read" }
    )
    @grant = @installation.github_repository_grants.create!(
      github_repository_id: 7654, full_name: "private-org/private-repo", enabled: true
    )
    stub_request(:get, "https://api.github.com/app/installations/987")
      .to_return(status: 200, body: JSON.generate(
        id: 987, app_id: 1234, permissions: { contents: "read" },
        suspended_at: nil
      ))
    stub_request(:post, "https://api.github.com/app/installations/987/access_tokens")
      .with { |request| JSON.parse(request.body).fetch("repository_ids") == [7654] }
      .to_return(status: 201, body: JSON.generate(token: "ghs-repo-scoped-token"))
  end

  teardown do
    @prior.each { |key, value| ENV[key] = value }
  end

  test "asynchronous GitHub SBOM report is imported only after completed download" do
    uuid = "4bab1a7e-da63-4828-9488-44e0e01a7c1b"
    stub_request(:get, "https://api.github.com/repos/private-org/private-repo/dependency-graph/sbom/generate-report")
      .to_return(status: 201, body: JSON.generate(
        sbom_url: "https://api.github.com/repos/private-org/private-repo/dependency-graph/sbom/fetch-report/#{uuid}"
      ))
    fetch = stub_request(:get, "https://api.github.com/repos/private-org/private-repo/dependency-graph/sbom/fetch-report/#{uuid}")
      .to_return(
        { status: 202, body: "" },
        { status: 302, headers: { "Location" => "https://objects.githubusercontent.com/test-report.json" }, body: "" }
      )
    spdx = JSON.parse(File.read(Rails.root.join("examples/sample_spdx.json")))
    download = stub_request(:get, "https://objects.githubusercontent.com/test-report.json")
      .with { |req| req.headers["Authorization"].nil? }
      .to_return(status: 200, body: JSON.generate(sbom: spdx))

    first = Github::SbomImporter.new.call(grant: @grant)
    assert_equal "pending", first.status
    assert_equal uuid, @grant.reload.sbom_report_uuid
    assert_equal 0, InventorySnapshot.count

    second = Github::SbomImporter.new.call(grant: @grant.reload)
    assert_equal "completed", second.status
    assert_equal "completed", @grant.reload.sbom_sync_status
    assert_nil @grant.sbom_report_uuid
    assert_equal 1, InventorySnapshot.count
    assert_equal "github", InventorySnapshot.last.source
    assert_equal "spdx", InventorySnapshot.last.format
    assert_nil InventorySnapshot.last.artifact.commit_sha
    assert_requested fetch, times: 2
    assert_requested download
  end

  test "download redirects to internal or unexpected hosts are blocked" do
    uuid = "4bab1a7e-da63-4828-9488-44e0e01a7c1b"
    @grant.update!(sbom_report_uuid: uuid, sbom_requested_at: Time.current,
      sbom_sync_status: "pending")
    stub_request(:get, "https://api.github.com/repos/private-org/private-repo/dependency-graph/sbom/fetch-report/#{uuid}")
      .to_return(status: 302, headers: { "Location" => "https://127.0.0.1/credentials" })

    assert_raises(Github::HttpClient::Error) do
      Github::SbomImporter.new.call(grant: @grant)
    end
    assert_equal 0, InventorySnapshot.count
    assert_equal "failed", @grant.reload.sbom_sync_status
  end

  test "revoked repository permission blocks SBOM import before GitHub API calls" do
    @grant.update!(enabled: false)
    assert_raises(Github::SbomImporter::PermissionError) do
      Github::SbomImporter.new.call(grant: @grant)
    end
    assert_equal 0, InventorySnapshot.count
  end

  test "sync reconciles granted repositories without deleting existing inventory" do
    other = @installation.github_repository_grants.create!(
      github_repository_id: 1234, full_name: "private-org/removed-repo", enabled: true
    )
    stub_request(:get, "https://api.github.com/app/installations/987")
      .to_return(status: 200, body: JSON.generate(
        id: 987, app_id: 1234, permissions: { contents: "read" }, suspended_at: nil
      ))
    stub_request(:post, "https://api.github.com/app/installations/987/access_tokens")
      .to_return(status: 201, body: JSON.generate(token: "ghs-synchronizer"))
    stub_request(:get, "https://api.github.com/installation/repositories?per_page=100&page=1")
      .to_return(status: 200, body: JSON.generate(repositories: [
        { id: 7654, full_name: "private-org/renamed-repo" }
      ]))

    count = Github::RepositorySynchronizer.new.call(installation: @installation)
    assert_equal 1, count
    assert_equal "private-org/renamed-repo", @grant.reload.full_name
    assert @grant.enabled?
    refute other.reload.enabled?
  end
end
