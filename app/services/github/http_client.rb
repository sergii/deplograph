require "json"
require "net/http"
require "uri"

module Github
  class HttpClient
    class Error < StandardError; end
    Result = Data.define(:status, :body, :location)

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

    def self.download(url)
      uri = URI.parse(url.to_s)
      # Only accept HTTPS GitHub-controlled download hosts. Do not forward
      # installation bearer tokens to temporary download URLs.
      allowed = uri.host == "objects.githubusercontent.com" ||
        uri.host == "github.com" ||
        uri.host&.match?(/\A[a-z0-9-]+\.githubusercontent\.com\z/)
      raise Error, "Untrusted GitHub SBOM download URL" unless
        uri.is_a?(URI::HTTPS) && allowed && uri.port == 443 &&
        uri.userinfo.nil? && uri.fragment.nil?

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
        open_timeout: 5, read_timeout: 20) do |http|
        request = Net::HTTP::Get.new(uri)
        request["Accept"] = "application/json"
        request["User-Agent"] = "Deplograph/0.3"
        http.request(request)
      end
      raise Error, "GitHub SBOM download HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
      raw = response.body.to_s
      raise Error, "GitHub SBOM exceeds size limit" if raw.bytesize > MAX_RESPONSE_BYTES
      JSON.parse(raw)
    rescue URI::InvalidURIError, JSON::ParserError
      raise Error, "Invalid GitHub SBOM download response"
    rescue Timeout::Error, SocketError, SystemCallError => error
      raise Error, "GitHub SBOM download network error: #{error.class}"
    end

    private

    def request(method, path, data: nil)
      unless path.is_a?(String) && path.start_with?("/") &&
             path.match?(%r{\A/[a-zA-Z0-9_.~/?&=%-]+\z}) &&
             !path.include?("..") && !path.include?("//")
        raise ArgumentError, "Invalid GitHub API path"
      end

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
      raise Error, "GitHub API HTTP #{status}" if status >= 400
      return Result.new(status: 302, body: {}, location: response["location"]) if status == 302

      raw = response.body.to_s
      raise Error, "GitHub API response too large" if raw.bytesize > MAX_RESPONSE_BYTES
      parsed = raw.empty? ? {} : JSON.parse(raw)
      Result.new(status: status, body: parsed, location: nil)
    rescue JSON::ParserError
      raise Error, "Invalid GitHub API JSON response"
    rescue Timeout::Error, SocketError, SystemCallError => error
      raise Error, "GitHub network error: #{error.class}"
    end
  end
end
