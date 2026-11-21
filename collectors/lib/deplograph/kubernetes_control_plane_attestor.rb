# frozen_string_literal: true

require "base64"
require "json"
require "net/http"
require "openssl"
require "securerandom"
require "time"
require "uri"
require_relative "kubernetes_collector"

module Deplograph
  module RuntimeCollectors
    class ControlPlaneApi
      MAX_PAGES = 20
      MAX_BYTES = 8 * 1024 * 1024

      def initialize(host:, port: 443, token_file:, ca_file:)
        raise Error, "Invalid Kubernetes API host" unless
          host.is_a?(String) && host.match?(/\A[a-zA-Z0-9.-]+\z/) && !host.include?("..")
        @host, @port, @token_file, @ca_file = host, Integer(port), token_file, ca_file
        raise Error, "Invalid Kubernetes API port" unless (1..65_535).cover?(@port)
      end

      def deployment(namespace, name)
        response = fetch("/apis/apps/v1/namespaces/#{namespace}/deployments/#{name}")
        raise Error, "Kubernetes Deployment response missing metadata" unless response["metadata"].is_a?(Hash)

        response
      end

      def replica_sets(namespace)
        pages("/apis/apps/v1/namespaces/#{namespace}/replicasets")
      end

      def pods(namespace)
        pages("/api/v1/namespaces/#{namespace}/pods")
      end

      private

      def pages(path)
        result = []
        cursor = nil
        MAX_PAGES.times do
          query = { limit: 500 }
          query[:continue] = cursor if cursor
          page = fetch(path, query: query)
          batch = page.fetch("items")
          raise Error, "Invalid Kubernetes listing" unless batch.is_a?(Array)

          result.concat(batch)
          cursor = page.fetch("metadata", {})["continue"].to_s
          return result if cursor.empty?
        end
        raise Error, "Kubernetes listing pagination exhausted"
      end

      def fetch(path, query: nil)
        token = File.read(@token_file).strip
        raise Error, "Kubernetes token is empty" if token.empty?

        uri = URI::HTTPS.build(host: @host, port: @port, path: path,
          query: query ? URI.encode_www_form(query) : nil)
        response = Net::HTTP.start(@host, @port, use_ssl: true,
          ca_file: @ca_file, verify_mode: OpenSSL::SSL::VERIFY_PEER,
          open_timeout: 5, read_timeout: 20) do |http|
          request = Net::HTTP::Get.new(uri)
          request["Authorization"] = "Bearer #{token}"
          http.request(request)
        end
        raise Error, "Kubernetes API returned HTTP #{response.code}" unless response.code.to_i == 200
        raise Error, "Kubernetes API returned too much data" if response.body.to_s.bytesize > MAX_BYTES

        result = JSON.parse(response.body)
        raise Error, "Unexpected Kubernetes response" unless result.is_a?(Hash)

        result
      rescue JSON::ParserError, KeyError
        raise Error, "Invalid Kubernetes API JSON"
      end
    end

    class KubernetesControlPlaneAttestor
      NAME = /\A[a-z0-9](?:[-a-z0-9.]*[a-z0-9])?\z/

      def initialize(namespace:, expected_workloads:, image_repository:, client:,
                     clock: -> { Time.now.utc })
        unless namespace.is_a?(String) && namespace.match?(NAME) &&
               expected_workloads.is_a?(Hash) && expected_workloads.size.between?(1, 20) &&
               expected_workloads.all? { |name, count|
                 name.is_a?(String) && name.match?(NAME) &&
                   count.is_a?(Integer) && count.between?(1, 1_000)
               } && expected_workloads.values.sum <= 1_000 &&
               image_repository.is_a?(String) && image_repository.match?(IMAGE_REPOSITORY)
          raise Error, "Invalid control-plane coverage contract"
        end
        @namespace, @expected, @repository, @client, @clock =
          namespace, expected_workloads, image_repository, client, clock
      end

      def collect
        pods = @client.pods(@namespace)
        replicasets = @client.replica_sets(@namespace)
        observed = @expected.sort.map do |workload, count|
          deployment = @client.deployment(@namespace, workload)
          uid = deployment.dig("metadata", "uid")
          generation = deployment.dig("metadata", "generation")
          spec = deployment.fetch("spec")
          status = deployment.fetch("status")
          selector = spec.fetch("selector").fetch("matchLabels")
          raise Error, "Cannot attest deployment with empty selector" unless selector.is_a?(Hash) && selector.any?
          raise Error, "Deployment UID is missing" unless uid.is_a?(String) && !uid.empty?
          raise Error, "Deployment rollout is incomplete" unless
            generation.is_a?(Integer) &&
            status.fetch("observedGeneration", 0) >= generation &&
            spec.fetch("replicas", 1) == count &&
            !spec.fetch("paused", false) &&
            %w[replicas readyReplicas updatedReplicas availableReplicas].all? { |key|
              status.fetch(key, 0) == count
            }

          template = spec.fetch("template").fetch("spec").fetch("containers")
          container = template.find { |entry| entry["name"] == workload }
          unless container && (
            container.fetch("image").start_with?("#{@repository}:") ||
            container.fetch("image").start_with?("#{@repository}@")
          )
            raise Error, "Deployment container image repository does not match attestor policy"
          end

          valid_rs = replicasets.filter_map do |rs|
            owners = Array(rs.dig("metadata", "ownerReferences"))
            rs.dig("metadata", "uid") if owners.any? { |owner|
              owner["uid"] == uid && owner["controller"] == true
            }
          end
          raise Error, "No owned ReplicaSets found" if valid_rs.empty?
          selected = pods.select do |pod|
            labels = pod.dig("metadata", "labels") || {}
            selector.all? { |key, value| labels[key] == value }
          end
          raise Error, "Pod count differs from rollout contract" unless selected.size == count

          replicas = selected.map do |pod|
            owner = Array(pod.dig("metadata", "ownerReferences"))
            unless owner.any? { |ref| valid_rs.include?(ref["uid"]) && ref["controller"] == true }
              raise Error, "Pod is not owned by an approved Deployment ReplicaSet"
            end
            raise Error, "Pod is terminating or not running" if
              pod.dig("metadata", "deletionTimestamp") ||
              pod.dig("status", "phase") != "Running"

            pod_uid = pod.dig("metadata", "uid")
            raise Error, "Invalid Pod UID" unless pod_uid.is_a?(String) &&
              pod_uid.match?(/\A[a-zA-Z0-9_.:-]{1,128}\z/)
            statuses = Array(pod.dig("status", "containerStatuses"))
            current = statuses.find { |entry| entry["name"] == workload }
            raise Error, "Application container is not ready" unless
              current && current["ready"] == true && current.dig("state", "running")

            image = RuntimeCollectors.image_identity(current["imageID"])
            raise Error, "ImageID does not identify a registry manifest" unless
              image && image.first == @repository

            { "uid" => pod_uid, "ready" => true, "image_digest" => image.last }
          end
          {
            "name" => workload, "desired_replicas" => count,
            "ready_replicas" => replicas.size,
            "replicas" => replicas.sort_by { |entry| entry.fetch("uid") }
          }
        end
        all_replicas = observed.flat_map { |workload| workload.fetch("replicas") }
        raise Error, "Same Pod included in multiple workloads" if
          all_replicas.map { |replica| replica.fetch("uid") }.uniq.size != all_replicas.size

        images = all_replicas.map { |replica| replica.fetch("image_digest") }.uniq
        raise Error, "Mixed OCI image digests prevent complete attestation" unless images.one?

        {
          "image_repository" => @repository, "image_digest" => images.first,
          "observed_at" => @clock.call.utc.iso8601, "workloads" => observed
        }
      rescue KeyError, NoMethodError
        raise Error, "Incomplete Kubernetes control-plane evidence"
      end
    end

    class SignedAttestationPublisher
      def initialize(url:, token:, private_key_file:, attestor_id:, repository:, environment:)
        @uri = URI.parse(url)
        unless @uri.scheme == "https" &&
               @uri.path == "/api/v1/runtime/attestations" &&
               @uri.userinfo.nil? && @uri.query.nil? && @uri.fragment.nil?
          raise Error, "HTTPS attestation endpoint required"
        end
        @token, @attestor_id, @repository, @environment = token, Integer(attestor_id), repository, environment
        raise Error, "Missing credential" if @token.to_s.empty?
        @key = OpenSSL::PKey.read(File.binread(private_key_file))
        raise Error, "Ed25519 private key required" unless @key.oid == "ED25519"
        begin
          @key.sign(nil, "deplograph-private-key-check-v1")
        rescue OpenSSL::PKey::PKeyError
          raise Error, "Ed25519 private key required"
        end
      end

      def publish(collected)
        challenge_uri = @uri.dup
        challenge_uri.path = "/api/v1/runtime/attestation_challenges"
        response = post(challenge_uri, { "attestor_id" => @attestor_id })
        raise Error, "Challenge rejected: HTTP #{response.code}" unless response.code.to_i == 201

        challenge = JSON.parse(response.body)
        payload = collected.merge(
          "version" => 1,
          "nonce" => challenge.fetch("nonce"),
          "attestor_id" => @attestor_id,
          "repository" => @repository, "environment" => @environment,
          "observation_id" => SecureRandom.uuid
        )
        canonical = JSON.generate(deep_sort(payload))
        signature = Base64.strict_encode64(@key.sign(nil, canonical))
        reply = post(@uri, {
          "attestor_id" => @attestor_id, "attestation" => payload, "signature" => signature
        })
        raise Error, "Attestation rejected: HTTP #{reply.code}" unless reply.code.to_i == 201

        JSON.parse(reply.body)
      end

      private

      def deep_sort(value)
        case value
        when Hash
          value.keys.sort.to_h { |key| [key, deep_sort(value.fetch(key))] }
        when Array
          value.map { |entry| deep_sort(entry) }
        else
          value
        end
      end

      def post(uri, payload)
        request = Net::HTTP::Post.new(uri)
        request["Authorization"] = "Bearer #{@token}"
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(payload)
        raise Error, "Attestation request too large" if request.body.bytesize > 100_000

        Net::HTTP.start(uri.host, uri.port, use_ssl: true,
          open_timeout: 5, read_timeout: 15) { |http| http.request(request) }
      end
    end
  end
end
