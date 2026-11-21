module Api
  module V1
    class ConfigurationDriftsController < BaseController
      rescue_from ActiveRecord::RecordNotFound do
        render json: { error: "Application or environment not found" }, status: :not_found
      end

      def create
        body = payload
        repo = body.fetch("repository")
        baseline_name = body.fetch("baseline_environment")
        target_name = body.fetch("target_environment")
        return unless authorize_integration!(
          permission: "read", repository: repo, environment: baseline_name
        )
        return unless authorize_integration!(
          permission: "read", repository: repo, environment: target_name
        )

        application = current_organization.applications.find_by!(
          repository_full_name: repo
        )
        diff = Configuration::KeyDiffer.new.call(
          application: application,
          baseline_name: baseline_name, target_name: target_name,
          workload: body.fetch("workload"), scope: body.fetch("scope")
        )
        comparison = DriftComparison.create!(
          organization: current_organization, application: application,
          baseline_environment: application.environments.find_by!(name: baseline_name),
          target_environment: application.environments.find_by!(name: target_name),
          mode: "configuration_names", status: diff.fetch(:status),
          compared_at: Time.current, result: {
            "status" => diff.fetch(:status), "mode" => "configuration_names",
            "verified_runtime" => false, "values_compared" => false,
            "dimensions" => { "environment_variables" => diff.as_json }
          }
        )
        render json: {
          id: comparison.id, status: comparison.status, result: comparison.result
        }, status: :created
      end
    end
  end
end
