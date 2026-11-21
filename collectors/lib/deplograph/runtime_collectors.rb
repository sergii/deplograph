# frozen_string_literal: true

require "digest"
require "json"
require "net/http"
require "openssl"
require "time"
require "uri"

module Deplograph
  module RuntimeCollectors
    class Error < StandardError; end

    DIGEST = /\Asha256:[a-f0-9]{64}\z/
    REPOSITORY = /\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/
    ENVIRONMENT = /\A[A-Za-z0-9_.-]{1,120}\z/
    IMAGE_REPOSITORY = %r{\A[a-zA-Z0-9._-]+(?:[:][0-9]+)?(?:/[a-zA-Z0-9._-]+)+\z}

    class Emitter
      def initialize(url:, token:, repository:, environment:, transport: Net::HTTP)
        @uri = URI.parse(url)
        unless @uri.path == "/api/v1/integration_events" &&
               @uri.query.nil? && @uri.fragment.nil? && @uri.userinfo.nil? &&
               (@uri.scheme == "https" ||
                (@uri.scheme == "http" && %w[127.0.0.1 localhost].include?(@uri.host)))
          raise Error, "An HTTPS Deplograph integration-events endpoint is required"
        end
        raise Error, "Collector credential missing" if token.to_s.empty?
        raise Error, "Invalid repository" unless repository.match?(REPOSITORY)
        raise Error, "Invalid environment" unless environment.match?(ENVIRONMENT)

        @token, @repository, @environment, @transport = token, repository, environment, transport
      end

      def send_event(event)
        payload = event.merge(
          "repository" => @repository, "environment" => @environment,
          "event_type" => "artifact.observed"
        )
        request = Net::HTTP::Post.new(@uri)
        request["Authorization"] = "Bearer #{@token}"
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(payload)
        raise Error, "Collector payload exceeds 64 KiB" if request.body.bytesize > 65_536

        response = @transport.start(@uri.host, @uri.port,
          use_ssl: @uri.scheme == "https", open_timeout: 5, read_timeout: 15
        ) { |http| http.request(request) }

        raise Error, "Deplograph rejected observation: HTTP #{response.code}" unless response.code.to_i == 202

        true
      end
    end

    def self.image_identity(image_id)
      value = image_id.to_s.delete_prefix("docker-pullable://")
      match = value.match(/\A(?<name>[A-Za-z0-9._\/:-]+)@sha256:(?<hex>[a-f0-9]{64})\z/)
      return nil unless match

      name = match[:name]
      return nil unless name.match?(IMAGE_REPOSITORY)

      [name, "sha256:#{match[:hex]}"]
    end

    def self.event_id(prefix:, identity:, collected_at:)
      "#{prefix}:#{Digest::SHA256.hexdigest(identity)[0, 24]}:#{collected_at.to_i}"
    end
  end
end
