# frozen_string_literal: true

require "json"
require "net/http"
require "securerandom"
require "time"
require "uri"
require_relative "runtime_collectors"

module Deplograph
  module RuntimeCollectors
    class EnvKeysCollector
      # Reads only Hash#keys. No process variable value is read, hashed or sent.
      # This is the executing process's environment, not proof of PID 1 state.
      def initialize(env:, source:, workload:, clock: -> { Time.now.utc })
        raise Error, "Unsupported observer source" unless
          %w[kubernetes kamal_agent docker_agent].include?(source)
        raise Error, "Invalid workload" unless
          workload.is_a?(String) && workload.match?(%r{\A[A-Za-z0-9_.\/-]{1,150}\z})

        @env, @source, @workload, @clock = env, source, workload, clock
      end

      def collect
        keys = @env.keys.select do |key|
          key.match?(/\A[A-Za-z_][A-Za-z0-9_]{0,127}\z/) &&
            !key.start_with?("DEPLOGRAPH_")
        end.sort.uniq
        raise Error, "Too many environment keys" if keys.size > 5_000

        {
          "source" => @source,
          "scope" => "process",
          "workload" => @workload,
          "collection_id" => SecureRandom.uuid,
          "collected_at" => @clock.call.utc.iso8601,
          # Filters out collector variables and cannot attest to target PID.
          "completeness" => "partial",
          "keys" => keys
        }
      end
    end

    class EnvKeysEmitter
      def initialize(url:, token:, repository:, environment:)
        @uri = URI.parse(url)
        unless @uri.path == "/api/v1/configuration_snapshots" &&
               @uri.query.nil? && @uri.fragment.nil? && @uri.userinfo.nil? &&
               (@uri.scheme == "https" ||
                (@uri.scheme == "http" && %w[localhost 127.0.0.1].include?(@uri.host)))
          raise Error, "Use an HTTPS configuration snapshots endpoint"
        end
        raise Error, "Collector token missing" if token.to_s.empty?
        raise Error, "Invalid repository" unless repository.match?(REPOSITORY)
        raise Error, "Invalid environment" unless environment.match?(ENVIRONMENT)

        @token, @repository, @environment = token, repository, environment
      end

      def send_snapshot(snapshot)
        body = JSON.generate(snapshot.merge(
          "repository" => @repository, "environment" => @environment
        ))
        raise Error, "Configuration payload too large" if body.bytesize > 100_000

        request = Net::HTTP::Post.new(@uri)
        request["Authorization"] = "Bearer #{@token}"
        request["Content-Type"] = "application/json"
        request.body = body
        response = Net::HTTP.start(@uri.host, @uri.port, use_ssl: @uri.scheme == "https",
          open_timeout: 5, read_timeout: 15) { |http| http.request(request) }
        raise Error, "Configuration snapshot rejected: HTTP #{response.code}" unless response.code.to_i == 201

        true
      end
    end
  end
end
