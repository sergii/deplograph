require "base64"

module Runtime
  class AcceptAttestation
    def call(attestor:, challenge:, body:, signature:)
      raise AttestationProtocol::Invalid, "Attestor is revoked or disabled" unless attestor.active?
      unless signature.is_a?(String) && signature.match?(/\A[A-Za-z0-9+\/]{85,88}={0,2}\z/)
        raise AttestationProtocol::Invalid, "Expected a Base64 Ed25519 signature"
      end
      raw_signature = Base64.strict_decode64(signature)
      raise AttestationProtocol::Invalid, "Invalid Ed25519 signature length" unless raw_signature.bytesize == 64

      RuntimeAttestation.transaction do
        challenge.lock!
        raise AttestationProtocol::Replay, "Challenge expired or already consumed" unless
          challenge.runtime_attestor_id == attestor.id && challenge.available?

        observed_at = AttestationProtocol.validate!(body, attestor, challenge)
        canonical = AttestationProtocol.canonical_json(body)
        unless attestor.signing_key.verify(nil, raw_signature, canonical)
          raise AttestationProtocol::Invalid, "Invalid attestation signature"
        end

        complete = AttestationProtocol.complete?(body, attestor)
        attestation = attestor.runtime_attestations.create!(
          runtime_attestation_challenge: challenge,
          observation_id: body.fetch("observation_id"),
          image_digest: body.fetch("image_digest"),
          observed_at: observed_at, verified_at: Time.current,
          ready_replicas: body.fetch("workloads").sum { |item| item.fetch("ready_replicas") },
          complete: complete,
          signed_payload: body, signature: signature
        )
        challenge.update!(consumed_at: Time.current)

        resolutions = Findings::ResolveWithAttestation.new.call(attestation)
        [attestation, resolutions]
      end
    rescue ArgumentError
      raise AttestationProtocol::Invalid, "Malformed Base64 signature"
    end
  end
end
