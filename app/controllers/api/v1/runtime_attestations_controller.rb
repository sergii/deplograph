module Api
  module V1
    class RuntimeAttestationsController < BaseController
      rescue_from ActiveRecord::RecordNotFound do
        render json: { error: "Attestor or challenge not found" }, status: :not_found
      end
      rescue_from Runtime::AttestationProtocol::Invalid do |error|
        render json: { error: error.message }, status: :unprocessable_entity
      end
      rescue_from Runtime::AttestationProtocol::Replay do |error|
        render json: { error: error.message }, status: :conflict
      end

      def create
        body = payload
        unless body.keys.sort == %w[attestation attestor_id signature]
          return render json: { error: "Unexpected fields" }, status: :unprocessable_entity
        end

        attestor = current_organization.runtime_attestors.find(body.fetch("attestor_id"))
        return unless allowed_attestor?(attestor)
        assertion = body.fetch("attestation")
        unless assertion.is_a?(Hash) && assertion["nonce"].is_a?(String)
          return render json: { error: "Invalid signed attestation" }, status: :unprocessable_entity
        end
        challenge = attestor.runtime_attestation_challenges.find_by!(nonce: assertion.fetch("nonce"))

        attestation, resolutions = Runtime::AcceptAttestation.new.call(
          attestor: attestor, challenge: challenge, body: assertion,
          signature: body.fetch("signature")
        )
        render json: {
          id: attestation.id, observation_id: attestation.observation_id,
          complete: attestation.complete, ready_replicas: attestation.ready_replicas,
          signature_verified: true, resolutions: resolutions.map(&:id)
        }, status: :created
      end

      private

      def allowed_attestor?(attestor)
        return true if attestor.active? &&
          attestor.integration_credential_id == current_credential.id &&
          current_credential.permits?(permission: "observe", provider: "kubernetes",
            repository: attestor.application.repository_full_name,
            environment: attestor.environment.name)

        render json: { error: "Attestor credential or scope is invalid" }, status: :forbidden
        false
      end
    end
  end
end
