require "json"
require "net/http"
require "securerandom"
require "uri"

module Github
  class OauthClient
    class Error < StandardError; end

    def self.authorization_url(state:, callback_url:)
      client_id = ENV.fetch("GITHUB_APP_CLIENT_ID")
      uri = URI("https://github.com/login/oauth/authorize")
      uri.query = URI.encode_www_form(client_id: client_id, state: state, redirect_uri: callback_url)
      uri.to_s
    end

    def exchange(code:, callback_url:)
      raise Error, "Missing GitHub authorization code" if code.blank?

      uri = URI("https://github.com/login/oauth/access_token")
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
        open_timeout: 5, read_timeout: 15) do |http|
        request = Net::HTTP::Post.new(uri)
        request["Accept"] = "application/json"
        request.set_form_data(
          client_id: ENV.fetch("GITHUB_APP_CLIENT_ID"),
          client_secret: ENV.fetch("GITHUB_APP_CLIENT_SECRET"),
          code: code, redirect_uri: callback_url
        )
        http.request(request)
      end
      raise Error, "GitHub OAuth HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      data = JSON.parse(response.body)
      raise Error, "GitHub authorization failed" if data["error"].present?
      token = data["access_token"]
      raise Error, "No GitHub user token returned" if token.blank?
      token
    rescue JSON::ParserError
      raise Error, "Invalid GitHub OAuth response"
    end

    def installations(user_token:)
      client = HttpClient.new(token: user_token)
      all = []
      1.upto(50) do |page|
        data = client.get("/user/installations?per_page=100&page=#{page}").body
        batch = data.fetch("installations")
        raise Error, "Invalid GitHub installation list" unless batch.is_a?(Array)
        all.concat(batch)
        raise Error, "Too many installations" if all.size > 5_000
        return all if batch.size < 100
      end
      raise Error, "GitHub installation pagination exceeded"
    end
  end
end
