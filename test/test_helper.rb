ENV["RAILS_ENV"] ||= "test"
ENV["SECRET_KEY_BASE"] ||= "test-secret-key-base-for-deplograph-tests-only"
require_relative "../config/environment"
require "rails/test_help"
require "webmock/minitest"

class ActiveSupport::TestCase
  self.use_transactional_tests = true
end

module IdentityTestHelpers
  def create_test_organization(slug: "org-#{SecureRandom.hex(6)}")
    Organization.create!(name: "Test #{slug}", slug: slug)
  end

  def issue_test_token(organization:, provider: "api", permissions: %w[read report],
                       repository_scopes: [], environment_scopes: [])
    _credential, token = IntegrationCredential.issue!(
      organization: organization,
      name: "Test #{provider} #{SecureRandom.hex(4)}",
      provider: provider, permissions: permissions,
      repository_scopes: repository_scopes,
      environment_scopes: environment_scopes
    )
    token
  end

  def bearer_headers(token)
    { "CONTENT_TYPE" => "application/json", "Authorization" => "Bearer #{token}" }
  end
end

class ActiveSupport::TestCase
  include IdentityTestHelpers
end
