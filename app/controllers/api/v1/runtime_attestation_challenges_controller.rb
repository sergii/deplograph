module Api
  module V1
    class RuntimeAttestationChallengesController < BaseController
      rescue_from ActiveRecord::RecordNotFound do
        render json: { error: "Attestor not found" }, status: :not_found
      end

      def create
        body = payload
        unless body.keys == ["attestor_id"]
          return render json: { error: "Expected attestor_id only" }, status: :unprocessable_entity
        end
        attestor = current_organization.runtime_attestors.find(body.fetch("attestor_id"))
        return unless allowed_attestor?(attestor)

        active_count = attestor.runtime_attestation_challenges
          .where(consumed_at: nil).where("expires_at > ?", Time.current).count
        if active_count >= 5
          return render json: { error: "Too many pending challenges" }, status: :too_many_requests
        end

        challenge = attestor.runtime_attestation_challenges.create!(
          nonce: SecureRandom.hex(32), expires_at: 5.minutes.from_now
        )
        render json: {
          attestor_id: attestor.id, nonce: challenge.nonce, expires_at: challenge.expires_at
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
