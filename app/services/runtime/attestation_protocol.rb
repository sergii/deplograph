require "json"
require "openssl"

module Runtime
  module AttestationProtocol
    VERSION = 1
    MAX_AGE = 2.minutes
    MAX_CLOCK_SKEW = 30.seconds
    DIGEST = /\Asha256:[a-f0-9]{64}\z/
    ID = /\A[a-zA-Z0-9_.:-]{1,128}\z/
    ROOT_KEYS = %w[
      version nonce attestor_id observation_id repository environment
      image_repository image_digest observed_at workloads
    ].freeze
    WORKLOAD_KEYS = %w[name desired_replicas ready_replicas replicas].freeze
    REPLICA_KEYS = %w[uid ready image_digest].freeze

    class Invalid < StandardError; end
    class Replay < StandardError; end

    module_function

    def canonical_json(value)
      JSON.generate(sort_json(value))
    end

    def sort_json(value)
      case value
      when Hash
        value.keys.sort.each_with_object({}) do |key, result|
          raise Invalid, "All signed JSON keys must be strings" unless key.is_a?(String)

          result[key] = sort_json(value.fetch(key))
        end
      when Array
        value.map { |item| sort_json(item) }
      else
        value
      end
    end

    def validate!(body, attestor, challenge)
      raise Invalid, "Attestation must be a JSON object" unless body.is_a?(Hash)
      raise Invalid, "Unexpected attestation fields" unless body.keys.sort == ROOT_KEYS.sort
      raise Invalid, "Protocol version must be 1" unless body["version"] == VERSION
      raise Invalid, "Challenge mismatch" unless body["nonce"] == challenge.nonce
      raise Invalid, "Attestor mismatch" unless body["attestor_id"] == attestor.id
      raise Invalid, "Repository mismatch" unless body["repository"] == attestor.application.repository_full_name
      raise Invalid, "Environment mismatch" unless body["environment"] == attestor.environment.name
      raise Invalid, "Image repository mismatch" unless body["image_repository"] == attestor.image_repository
      raise Invalid, "Invalid observation ID" unless body["observation_id"].is_a?(String) &&
        body["observation_id"].match?(ID)
      raise Invalid, "Invalid OCI image digest" unless body["image_digest"].is_a?(String) &&
        body["image_digest"].match?(DIGEST)

      observed_at = Time.iso8601(body.fetch("observed_at"))
      if observed_at < Time.current - MAX_AGE ||
         observed_at > Time.current + MAX_CLOCK_SKEW ||
         observed_at < challenge.created_at - MAX_CLOCK_SKEW
        raise Invalid, "Attestation observation is not fresh"
      end

      workloads = body.fetch("workloads")
      unless workloads.is_a?(Array) && workloads.size.between?(1, 20)
        raise Invalid, "Expected a bounded workload list"
      end
      all_uids = []
      workloads.each do |workload|
        unless workload.is_a?(Hash) && workload.keys.sort == WORKLOAD_KEYS.sort &&
               workload["name"].is_a?(String) &&
               workload["name"].match?(/\A[a-z0-9](?:[-a-z0-9.]*[a-z0-9])?\z/) &&
               workload["name"].length <= 120 &&
               workload["desired_replicas"].is_a?(Integer) &&
               workload["desired_replicas"].between?(0, 1_000) &&
               workload["ready_replicas"].is_a?(Integer) &&
               workload["ready_replicas"].between?(0, 1_000)
          raise Invalid, "Invalid workload coverage assertion"
        end
        replicas = workload.fetch("replicas")
        unless replicas.is_a?(Array) && replicas.size <= 1_000
          raise Invalid, "Invalid replica list"
        end

        replicas.each do |replica|
          unless replica.is_a?(Hash) && replica.keys.sort == REPLICA_KEYS.sort &&
                 replica["uid"].is_a?(String) && replica["uid"].match?(ID) &&
                 [true, false].include?(replica["ready"]) &&
                 replica["image_digest"].is_a?(String) &&
                 replica["image_digest"].match?(DIGEST)
            raise Invalid, "Invalid signed replica data"
          end
          all_uids << replica["uid"]
        end
      end
      raise Invalid, "Replica IDs must be unique across workloads" unless all_uids.uniq.size == all_uids.size
      raise Invalid, "Workload names must be unique" unless
        workloads.map { |item| item["name"] }.uniq.size == workloads.size
      raise Invalid, "More than 1000 replicas" if all_uids.size > 1_000

      observed_at
    rescue ArgumentError, KeyError
      raise Invalid, "Invalid attestation timestamp or fields"
    end

    def complete?(body, attestor)
      claimed = body.fetch("workloads").index_by { |item| item.fetch("name") }
      expected = attestor.expected_workloads
      return false unless claimed.keys.sort == expected.keys.sort

      expected.all? do |name, count|
        item = claimed.fetch(name)
        replicas = item.fetch("replicas")
        item["desired_replicas"] == count &&
          item["ready_replicas"] == count &&
          replicas.size == count &&
          replicas.all? { |replica|
            replica["ready"] == true &&
              replica["image_digest"] == body["image_digest"]
          }
      end
    end
  end
end
