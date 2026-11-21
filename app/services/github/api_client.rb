require "base64"
require "json"
require "net/http"
require "uri"

module Github
  class ApiClient
    class ApiError < StandardError; end

    ALLOWED_FILES = %w[
      Dockerfile Gemfile.lock .ruby-version .tool-versions
      package-lock.json pnpm-lock.yaml yarn.lock
      compose.yml compose.yaml docker-compose.yml
    ].freeze
    MAX_FILE_BYTES = 1_000_000

    def initialize(token: ENV["GITHUB_TOKEN"], base_url: "https://api.github.com")
      @token = token
      @base_url = base_url.chomp("/")
    end

    def repository(full_name)
      get("/repos/#{validated_name(full_name)}")
    end

    # Only an allowlisted set of build manifests is fetched.
    def file(full_name, path, ref: nil)
      raise ArgumentError, "Unsupported manifest" unless ALLOWED_FILES.include?(path)

      query = ref.present? ? "?ref=#{URI.encode_www_form_component(ref)}" : ""
      data = get("/repos/#{validated_name(full_name)}/contents/#{path}#{query}")
      return nil unless data
      raise ApiError, "Manifest too large" if data.fetch("size", 0).to_i > MAX_FILE_BYTES
      raise ApiError, "Only regular files are supported" unless data["type"] == "file"

      content = Base64.strict_decode64(data.fetch("content").delete("\n"))
      raise ApiError, "Manifest too large" if content.bytesize > MAX_FILE_BYTES

      content
    end

    private

    def validated_name(value)
      raise ArgumentError, "Invalid repository name" unless value.match?(/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/)

      value
    end

    def get(path)
      uri = URI("#{@base_url}#{path}")
      request = Net::HTTP::Get.new(uri)
      request["Accept"] = "application/vnd.github+json"
      request["X-GitHub-Api-Version"] = "2026-03-10"
      request["User-Agent"] = "Deplograph/0.1"
      request["Authorization"] = "Bearer #{@token}" if @token.present?
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                 open_timeout: 5, read_timeout: 15) { |http| http.request(request) }

      return nil if response.code == "404"
      raise ApiError, "GitHub HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    rescue JSON::ParserError => error
      raise ApiError, "Invalid GitHub response: #{error.message}"
    end
  end
end
