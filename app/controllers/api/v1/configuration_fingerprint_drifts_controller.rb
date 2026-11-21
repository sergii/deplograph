module Api
  module V1
    class ConfigurationFingerprintDriftsController < BaseController
      ALLOWED = %w[
        repository baseline_environment target_environment workload scope
      ].freeze

      rescue_from ActiveRecord::RecordNotFound do
        render json: { error: "Application or environment not found" }, status: :not_found
      end

      def create
        body = payload
        unless (body.keys - ALLOWED).empty?
          return render json: { error: "Unexpected fingerprint comparison fields" },
            status: :unprocessable_entity
        end

        repository = body.fetch("repository")
        left = body.fetch("baseline_environment")
        right = body.fetch("target_environment")
        return unless authorize_integration!(
          permission: "read", repository: repository, environment: left
        )
        return unless authorize_integration!(
          permission: "read", repository: repository, environment: right
        )

        app = current_organization.applications.find_by!(repository_full_name: repository)
        diff = Configuration::FingerprintDiffer.new.call(
          application: app, baseline_name: left, target_name: right,
          workload: body.fetch("workload"), scope: body.fetch("scope")
        )
        comparison = DriftComparison.create!(
          organization: current_organization, application: app,
          baseline_environment: app.environments.find_by!(name: left),
          target_environment: app.environments.find_by!(name: right),
          mode: "configuration_fingerprints", status: diff.fetch(:status),
          compared_at: Time.current, result: {
            "status" => diff.fetch(:status), "mode" => "configuration_fingerprints",
            "verified_runtime" => false, "plaintext_collected" => false,
            "dimensions" => { "environment_value_fingerprints" => diff.as_json }
          }
        )
        render json: {
          id: comparison.id, status: comparison.status, result: comparison.result
        }, status: :created
      end
    end
  end
end
