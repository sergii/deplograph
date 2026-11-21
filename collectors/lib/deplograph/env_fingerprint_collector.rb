# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "time"
require "uri"
require_relative "env_keys_collector"

module Deplograph
  module RuntimeCollectors
    class EnvFingerprintCollector
      ALGORITHM = "HMAC-SHA256-v1"
      KEY_ID_PATTERN = /\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}\z/

      def initialize(env:, source:, workload:, repository:, key_id:, key_file:,
                     clock: -> { Time.now.utc })
        raise Error, "Invalid HMAC key identifier" unless
          key_id.is_a?(String) && key_id.match?(KEY_ID_PATTERN)
        raise Error, "Invalid repository" unless repository.match?(REPOSITORY)

        @key = File.binread(key_file)
        raise Error, "HMAC key must contain at least 32 random bytes" if @key.bytesize < 32

        @env, @source, @workload, @repository, @key_id, @clock =
          env, source, workload, repository, key_id, clock
      end

      def collect
        names = EnvKeysCollector.new(env: @env, source: @source,
          workload: @workload, clock: @clock).collect

        # The secret values are read only locally for HMAC and never serialized
        # into the outgoing payload. Domain separation includes the repo and key.
        fingerprints = names.fetch("keys").to_h do |name|
          value = @env.fetch(name)
          raise Error, "ENV value must be a String" unless value.is_a?(String)

          message = JSON.generate([
            "deplograph-env-value-v1", @repository, name, value
          ])
          [name, OpenSSL::HMAC.hexdigest("SHA256", @key, message)]
        end

        {
          names: names,
          fingerprint_batch: {
            "key_id" => @key_id,
            "algorithm" => ALGORITHM,
            "fingerprints" => fingerprints
          }
        }
      end
    end

    class EnvFingerprintPublisher
      def initialize(names_url:, token:, repository:, environment:)
        @names = EnvKeysEmitter.new(url: names_url, token: token,
          repository: repository, environment: environment)
        @token, @repository, @environment = token, repository, environment
        @fingerprint_uri = URI.parse(names_url.sub(%r{/configuration_snapshots\z},
          "/configuration/fingerprints"))
        unless @fingerprint_uri.path == "/api/v1/configuration/fingerprints" &&
               @fingerprint_uri.query.nil? && @fingerprint_uri.fragment.nil?
          raise Error, "Invalid fingerprint endpoint"
        end
      end

      def publish(collection)
        snapshot_id = @names.send_snapshot(collection.fetch(:names), return_id: true)
        body = JSON.generate(collection.fetch(:fingerprint_batch).merge(
          "snapshot_id" => snapshot_id,
          "repository" => @repository, "environment" => @environment
        ))
        raise Error, "Fingerprint payload too large" if body.bytesize > 380_000

        request = Net::HTTP::Post.new(@fingerprint_uri)
        request["Authorization"] = "Bearer #{@token}"
        request["Content-Type"] = "application/json"
        request.body = body
        response = Net::HTTP.start(@fingerprint_uri.host, @fingerprint_uri.port,
          use_ssl: @fingerprint_uri.scheme == "https",
          open_timeout: 5, read_timeout: 15) { |http| http.request(request) }
        raise Error, "Fingerprint batch rejected: HTTP #{response.code}" unless
          response.code.to_i == 201

        snapshot_id
      end
    end
  end
end
