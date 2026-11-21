require "digest"
require "json"
require "time"

module Configuration
  class SnapshotRecorder
    class Conflict < StandardError; end
    class InvalidSnapshot < StandardError; end

    MAX_KEYS = 5_000
    KEY_PATTERN = /\A[A-Za-z_][A-Za-z0-9_]{0,127}\z/
    WORKLOAD_PATTERN = %r{\A[A-Za-z0-9_.\/-]{1,150}\z}
    DELIVERY_PATTERN = /\A[A-Za-z0-9_.:-]{1,160}\z/
    MAX_AGE = 365.days

    def call(environment:, source:, scope:, workload:, collection_id:,
             completeness:, collected_at:, keys:)
      raise InvalidSnapshot, "Destroyed environment cannot accept snapshots" if environment.state == "destroyed"
      raise InvalidSnapshot, "Invalid source" unless IntegrationCredential::PROVIDERS.include?(source)
      raise InvalidSnapshot, "Invalid scope" unless ConfigurationSnapshot::SCOPES.include?(scope)
      raise InvalidSnapshot, "Invalid completeness" unless ConfigurationSnapshot::COMPLETENESS.include?(completeness)
      raise InvalidSnapshot, "Invalid workload" unless workload.is_a?(String) && workload.match?(WORKLOAD_PATTERN)
      raise InvalidSnapshot, "Invalid collection ID" unless collection_id.is_a?(String) && collection_id.match?(DELIVERY_PATTERN)
      unless keys.is_a?(Array) && keys.size <= MAX_KEYS &&
             keys.all? { |name| name.is_a?(String) && name.match?(KEY_PATTERN) } &&
             keys.size == keys.uniq.size
        raise InvalidSnapshot, "Only a unique array of ENV variable names is accepted"
      end

      recorded_at = Time.iso8601(collected_at.to_s)
      if recorded_at < Time.current - MAX_AGE || recorded_at > Time.current + 5.minutes
        raise InvalidSnapshot, "Collected timestamp is out of range"
      end
      names = keys.sort
      digest = Digest::SHA256.hexdigest(JSON.generate(names))

      ConfigurationSnapshot.transaction do
        existing = environment.configuration_snapshots.find_by(
          source: source, collection_id: collection_id
        )
        if existing
          unless existing.keys_sha256 == digest && existing.scope == scope &&
                 existing.workload == workload && existing.completeness == completeness &&
                 existing.collected_at.to_i == recorded_at.to_i
            raise Conflict, "Collection ID reused with different evidence"
          end
          next existing
        end

        snapshot = environment.configuration_snapshots.create!(
          source: source, scope: scope, workload: workload,
          collection_id: collection_id, completeness: completeness,
          collected_at: recorded_at, keys_sha256: digest
        )
        names.each do |name|
          snapshot.configuration_entries.create!(name: name)
        end
        snapshot
      end
    rescue ArgumentError
      raise InvalidSnapshot, "Invalid collected timestamp"
    end
  end
end
