require "base64"
require "openssl"
require "json"

module Github
  class AppClient
    class ConfigurationError < StandardError; end

    def self.configured?
      %w[GITHUB_APP_ID GITHUB_APP_CLIENT_ID GITHUB_APP_CLIENT_SECRET
         GITHUB_APP_PRIVATE_KEY].all? { |name| ENV[name].present? }
    end

    def initialize(app_id: ENV["GITHUB_APP_ID"], private_key: ENV["GITHUB_APP_PRIVATE_KEY"])
      raise ConfigurationError, "GitHub App credentials not configured" if
        app_id.blank? || private_key.blank?

      @app_id = Integer(app_id)
      @private_key = OpenSSL::PKey::RSA.new(private_key.gsub("\\n", "\n"))
    rescue ArgumentError, OpenSSL::PKey::RSAError
      raise ConfigurationError, "Invalid GitHub App signing configuration"
    end

    def installation(id)
      HttpClient.new(token: app_jwt).get("/app/installations/#{Integer(id)}").body
    end

    def installation_token(id, repository_ids: nil)
      data = { permissions: { contents: "read" } }
      data[:repository_ids] = repository_ids if repository_ids&.any?
      response = HttpClient.new(token: app_jwt)
        .post("/app/installations/#{Integer(id)}/access_tokens", data)
      raise HttpClient::Error, "No installation access token returned" unless
        response.body["token"].present?

      response.body.fetch("token")
    end

    def repositories(id)
      token = installation_token(id)
      client = HttpClient.new(token: token)
      results = []
      1.upto(50) do |page|
        data = client.get("/installation/repositories?per_page=100&page=#{page}").body
        batch = data.fetch("repositories")
        raise HttpClient::Error, "Invalid installation repositories response" unless batch.is_a?(Array)

        results.concat(batch)
        raise HttpClient::Error, "Too many repositories to sync" if results.size > 5_000
        return results if batch.size < 100
      end
      raise HttpClient::Error, "GitHub pagination limit exceeded"
    end

    private

    def app_jwt
      now = Time.now.to_i
      header = { alg: "RS256", typ: "JWT" }
      payload = { iat: now - 60, exp: now + 8.minutes.to_i, iss: @app_id }
      unsigned = [header, payload].map do |part|
        Base64.urlsafe_encode64(JSON.generate(part), padding: false)
      end.join(".")
      signature = @private_key.sign(OpenSSL::Digest::SHA256.new, unsigned)
      "#{unsigned}.#{Base64.urlsafe_encode64(signature, padding: false)}"
    end
  end
end
