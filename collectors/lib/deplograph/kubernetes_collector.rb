# frozen_string_literal: true

require_relative "runtime_collectors"

module Deplograph
  module RuntimeCollectors
    class KubernetesCollector
      def initialize(namespace:, client:, clock: -> { Time.now.utc })
        raise Error, "Invalid namespace" unless namespace.match?(/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/)

        @namespace, @client, @clock = namespace, client, clock
      end

      def collect
        @client.list_pods(@namespace).flat_map do |pod|
          next [] unless pod.dig("status", "phase") == "Running"

          metadata = pod.fetch("metadata")
          pod_name = metadata.fetch("name")
          uid = metadata.fetch("uid")
          next [] unless pod_name.match?(/\A[a-z0-9.-]+\z/) && uid.match?(/\A[-a-z0-9]+\z/)

          labels = metadata.fetch("labels", {})
          logical_workload = labels["app.kubernetes.io/name"] || labels["app"] || pod_name
          Array(pod.dig("status", "containerStatuses")).filter_map do |container|
            next unless container.dig("state", "running")

            identity = RuntimeCollectors.image_identity(container["imageID"])
            next unless identity

            name = container.fetch("name")
            next unless name.match?(/\A[a-z0-9.-]+\z/)

            image, digest = identity
            observed_at = @clock.call.utc
            instance_id = "#{uid}/#{name}"
            workload = "#{@namespace}/#{pod_name}/#{name}"
            next if workload.length > 150

            {
              "source" => "kubernetes",
              "event_id" => RuntimeCollectors.event_id(prefix: "k8s",
                identity: "#{instance_id}/#{container["containerID"]}", collected_at: observed_at),
              "occurred_at" => observed_at.iso8601,
              "workload" => workload,
              "image" => image,
              "image_digest" => digest,
              "artifact_identifier" => "oci:#{image}@#{digest}",
              "metadata" => {
                "namespace" => @namespace,
                "pod_uid" => uid,
                "container_name" => name,
                "instance_id" => instance_id,
                "logical_workload" => "#{logical_workload}/#{name}",
                "coverage" => "partial"
              }
            }
          end
        end
      end
    end

    class KubernetesApi
      MAX_PAGES = 20
      MAX_BODY = 8 * 1024 * 1024

      def initialize(host:, port: 443, token_file:,
                     ca_file:, selector: nil)
        raise Error, "Invalid Kubernetes host" unless
          host.match?(/\A[a-zA-Z0-9.-]+\z/) && !host.include?("..")
        raise Error, "Invalid Kubernetes port" unless (1..65_535).cover?(Integer(port))

        @host, @port, @token_file, @ca_file, @selector =
          host, Integer(port), token_file, ca_file, selector
      end

      def list_pods(namespace)
        token = File.read(@token_file).strip
        raise Error, "Kubernetes service account token missing" if token.empty?

        result = []
        cursor = nil
        MAX_PAGES.times do
          params = { limit: "500" }
          params[:labelSelector] = @selector if @selector && !@selector.empty?
          params[:continue] = cursor if cursor
          uri = URI::HTTPS.build(host: @host, port: @port,
            path: "/api/v1/namespaces/#{namespace}/pods",
            query: URI.encode_www_form(params))
          response = Net::HTTP.start(@host, @port, use_ssl: true,
            ca_file: @ca_file, verify_mode: OpenSSL::SSL::VERIFY_PEER,
            open_timeout: 5, read_timeout: 20) do |http|
            request = Net::HTTP::Get.new(uri)
            request["Authorization"] = "Bearer #{token}"
            http.request(request)
          end
          raise Error, "Kubernetes list Pods HTTP #{response.code}" unless response.code.to_i == 200
          body = response.body.to_s
          raise Error, "Kubernetes response too large" if body.bytesize > MAX_BODY
          page = JSON.parse(body)
          batch = page.fetch("items")
          raise Error, "Invalid Pods response" unless batch.is_a?(Array)

          result.concat(batch)
          cursor = page.fetch("metadata", {})["continue"].to_s
          return result if cursor.empty?
        end
        raise Error, "Kubernetes pagination limit reached"
      rescue JSON::ParserError, KeyError => error
        raise Error, "Invalid Kubernetes response: #{error.class}"
      end
    end
  end
end
