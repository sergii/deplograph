# frozen_string_literal: true

require "open3"
require "socket"
require_relative "runtime_collectors"

module Deplograph
  module RuntimeCollectors
    class DockerApi
      def initialize(command: ["docker"])
        @command = command
      end

      def list(service:)
        output = run("ps", "--filter", "label=service=#{service}", "--format", "{{.ID}}")
        output.lines.map(&:strip).reject(&:empty?)
      end

      def container(id)
        result = JSON.parse(run("inspect", "--type", "container", id))
        result.fetch(0)
      end

      def image(id)
        JSON.parse(run("image", "inspect", id)).fetch(0)
      end

      private

      def run(*args)
        out, stderr, status = Open3.capture3(*@command, *args)
        raise Error, "Docker operation failed: #{args.first}" unless status.success?
        raise Error, "Docker response too large" if out.bytesize > 8 * 1024 * 1024

        out
      end
    end

    class KamalCollector
      def initialize(service:, image_repository:, docker:, destination: nil,
                     host_id: Socket.gethostname, clock: -> { Time.now.utc })
        unless service.match?(/\A[a-zA-Z0-9_.-]{1,80}\z/) &&
               image_repository.match?(IMAGE_REPOSITORY) &&
               (destination.nil? || destination.match?(/\A[a-zA-Z0-9_.-]{1,80}\z/)) &&
               host_id.match?(/\A[a-zA-Z0-9_.-]{1,80}\z/)
          raise Error, "Invalid Kamal collector configuration"
        end

        @service, @image_repository, @docker = service, image_repository, docker
        @destination, @host_id, @clock = destination, host_id, clock
      end

      def collect
        @docker.list(service: @service).filter_map do |id|
          container = @docker.container(id)
          next unless container.fetch("State", {})["Running"] == true

          labels = container.dig("Config", "Labels") || {}
          next unless labels["service"] == @service
          next if @destination && labels["destination"] != @destination

          # A local Docker image ID is not an OCI registry manifest digest.
          # Require exactly one matching RepoDigest for the configured repo.
          image_id = container["Image"]
          image = @docker.image(image_id)
          matching = Array(image["RepoDigests"]).filter_map do |item|
            RuntimeCollectors.image_identity(item)
          end.select { |repo, _digest| repo == @image_repository }.uniq
          next unless matching.size == 1

          image_name, digest = matching.first
          role = labels.fetch("role", "web")
          next unless role.match?(/\A[a-zA-Z0-9_.-]{1,80}\z/)

          instance_id = container.fetch("Id")
          next unless instance_id.match?(/\A[a-f0-9]{64}\z/)

          observed_at = @clock.call.utc
          workload = "#{@service}/#{role}/#{@host_id}/#{instance_id[0, 12]}"
          next if workload.length > 150

          {
            "source" => "kamal_agent",
            "event_id" => RuntimeCollectors.event_id(prefix: "kamal",
              identity: "#{instance_id}/#{image_id}", collected_at: observed_at),
            "occurred_at" => observed_at.iso8601,
            "workload" => workload,
            "image" => image_name,
            "image_digest" => digest,
            "artifact_identifier" => "oci:#{image_name}@#{digest}",
            "metadata" => {
              "service" => @service, "role" => role,
              "instance_id" => instance_id, "host_id" => @host_id,
              "logical_workload" => "#{@service}/#{role}",
              "coverage" => "partial"
            }
          }
        end
      end
    end
  end
end
