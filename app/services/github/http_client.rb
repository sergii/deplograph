require "json"
require "net/http"
require "uri"

module Github
  class HttpClient
    class Error < StandardError; end
    Result = Data.define(:status, :body)

    MAX_RESPONSE_BYTES = 16 * 1024 * 1024
    BASE_URL = "https://api.github.com"

    def initialize(token: nil)
      @token = token
    end

    def get(path)
      request(:get, path)
    end

    def post(path, data)
      request(:post, path, data: data)
    end

    private

    def request(method, path, data: nil)
      raise ArgumentError, "Invalid GitHub API path" unless
        path.is_a?(String) && path.match?(%r{\A/(?:[A-Za-z0-9_.~%-]+/?|\?[^/]+)*\z}) &&
        !path.include?("..")

      uri = URI("#{BASE_URL}#{path}")
      request = method == :get ? Net::HTTP::Get.new(uri) : Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{@token}" if @token.present?
      request["Accept"] = "application/vnd.github+json"
      request["X-GitHub-Api-Version"] = "2026-03-10"
      request["User-Agent"] = "Deplograph/0.3"
      if data
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(data)
      end
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
        open_timeout: 5, read_timeout: 20) { |http| http.request(request) }

      status = response.code.to_i
      if status >= 400
        raise Error, "GitHub API HTTP #{status}"
      end
      raw = response.body.to_s
      raise Error, "GitHub API response too large" if raw.bytesize > MAX_RESPONSE_BYTES
      parsed = raw.empty? ? {} : JSON.parse(raw)
      Result.new(status: status, body: parsed)
    rescue JSON::ParserError
      raise Error, "Invalid GitHub API JSON response"
    rescue Timeout::Error, SocketError, SystemCallError => error
      raise Error, "GitHub network error: #{error.class}"
    end
  end
end
