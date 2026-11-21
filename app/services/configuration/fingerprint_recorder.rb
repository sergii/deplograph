require "digest"
require "json"

module Configuration
  class FingerprintRecorder
    class InvalidEvidence < StandardError; end
    class Conflict < StandardError; end

    MAX_KEYS = 5_000
    DIGEST_PATTERN = /\A[a-f0-9]{64}\z/
    KEY_ID_PATTERN = /\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}\z/
    MAX_SNAPSHOT_DELAY = 10.minutes

    def call(snapshot:, key_id:, algorithm:, fingerprints:)
      unless key_id.is_a?(String) && key_id.match?(KEY_ID_PATTERN) &&
             algorithm == ConfigurationFingerprintBatch::ALGORITHM
        raise InvalidEvidence, "Invalid key identifier or unsupported HMAC algorithm"
      end
      unless fingerprints.is_a?(Hash) && fingerprints.size <= MAX_KEYS &&
             fingerprints.all? { |name, digest|
               name.is_a?(String) && name.match?(SnapshotRecorder::KEY_PATTERN) &&
                 digest.is_a?(String) && digest.match?(DIGEST_PATTERN)
             }
        raise InvalidEvidence, "Expected ENV names mapped to 64-character HMAC digests"
      end

      sorted = fingerprints.sort.to_h
      content_digest = Digest::SHA256.hexdigest(JSON.generate(sorted))
      entries = snapshot.configuration_entries.index_by(&:name)
      unless (sorted.keys - entries.keys).empty?
        raise InvalidEvidence, "Fingerprint names must belong to the configuration snapshot"
      end

      ConfigurationFingerprintBatch.transaction do
        previous = snapshot.configuration_fingerprint_batches.lock.find_by(key_id: key_id)
        if previous
          unless previous.algorithm == algorithm && previous.fingerprints_sha256 == content_digest
            raise Conflict, "A fingerprint key ID was already used with different evidence"
          end
          next previous
        end

        if snapshot.collected_at < Time.current - MAX_SNAPSHOT_DELAY
          raise InvalidEvidence, "Snapshot is too old to attach fresh value fingerprints"
        end
        batch = snapshot.configuration_fingerprint_batches.create!(
          key_id: key_id, algorithm: algorithm,
          fingerprints_sha256: content_digest, collected_at: Time.current
        )
        sorted.each do |name, digest|
          batch.configuration_fingerprints.create!(
            configuration_entry: entries.fetch(name), digest: digest
          )
        end
        batch
      end
    end
  end
end
