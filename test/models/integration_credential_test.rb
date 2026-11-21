require "test_helper"

class IntegrationCredentialTest < ActiveSupport::TestCase
  setup do
    @organization = create_test_organization
  end

  test "secrets are issued once, authenticated by digest and never stored raw" do
    credential, token = IntegrationCredential.issue!(
      organization: @organization, name: "build reports", provider: "github_actions",
      permissions: %w[report], repository_scopes: ["acme/app"],
      environment_scopes: ["production"]
    )
    assert token.start_with?("dpl_")
    assert_equal credential.id, IntegrationCredential.authenticate("Bearer #{token}").id
    refute_equal token, credential.token_digest
    assert_nil IntegrationCredential.authenticate("Bearer #{token}wrong")
    assert credential.permits?(permission: "report", repository: "acme/app",
                                environment: "production", provider: "github_actions")
    refute credential.permits?(permission: "report", repository: "acme/other",
                               environment: "production", provider: "github_actions")
    refute credential.permits?(permission: "observe", repository: "acme/app",
                               environment: "production", provider: "github_actions")
    refute credential.permits?(permission: "report", repository: "acme/app",
                               environment: "staging", provider: "github_actions")
    refute credential.permits?(permission: "report", repository: "acme/app",
                               environment: "production", provider: "kamal")
  end

  test "observe permission is limited to actual observer sources" do
    credential = IntegrationCredential.new(
      organization: @organization, name: "bad", provider: "github_actions",
      permissions: %w[observe], token_prefix: SecureRandom.hex(8),
      token_digest: SecureRandom.hex(32)
    )
    refute credential.valid?
    assert credential.errors[:provider].any?
  end

  test "credentials cannot have malformed or duplicate scope entries" do
    credential = IntegrationCredential.new(
      organization: @organization, name: "invalid", provider: "api",
      permissions: %w[read read], repository_scopes: ["../../etc/passwd"],
      environment_scopes: ["production", "production"],
      token_prefix: SecureRandom.hex(8), token_digest: SecureRandom.hex(32)
    )
    refute credential.valid?
    assert credential.errors[:permissions].any?
    assert credential.errors[:repository_scopes].any?
    assert credential.errors[:environment_scopes].any?
  end
end
