module Api
  module V1
    class ConfigurationFingerprintsController < BaseController
      ALLOWED = %w[
        repository environment snapshot_id key_id algorithm fingerprints
      ].freeze

      rescue_from Configuration::FingerprintRecorder::InvalidEvidence do |error|
        render json: { error: error.message }, status: :unprocessable_entity
      end
      rescue_from Configuration::FingerprintRecorder::Conflict do |error|
        render json: { error: error.message }, status: :conflict
      end
      rescue_from ActiveRecord::RecordNotFound do
        render json: { error: "Snapshot not found" }, status: :not_found
      end

      def create
        body = payload
        unless (body.keys - ALLOWED).empty?
          return render json: { error: "Unsupported fields; plaintext values are not accepted" },
            status: :unprocessable_entity
        end

        repository = body.fetch("repository")
        environment_name = body.fetch("environment")
        unless %w[report observe].any? { |permission|
          current_credential.permits?(permission: permission, repository: repository,
            environment: environment_name)
        }
          return render json: { error: "Insufficient credential scope" }, status: :forbidden
        end
        app = current_organization.applications.find_by!(repository_full_name: repository)
        environment = app.environments.find_by!(name: environment_name)
        snapshot = environment.configuration_snapshots.find(body.fetch("snapshot_id"))
        permission = snapshot.scope == "process" ? "observe" : "report"
        return unless authorize_integration!(
          permission: permission, repository: repository,
          environment: environment_name, provider: snapshot.source
        )

        batch = Configuration::FingerprintRecorder.new.call(
          snapshot: snapshot,
          key_id: body.fetch("key_id"), algorithm: body.fetch("algorithm"),
          fingerprints: body.fetch("fingerprints")
        )
        render json: {
          id: batch.id, snapshot_id: snapshot.id,
          key_id: batch.key_id, algorithm: batch.algorithm,
          fingerprint_count: batch.configuration_fingerprints.count,
          collected_at: batch.collected_at
        }, status: :created
      end
    end
  end
end
