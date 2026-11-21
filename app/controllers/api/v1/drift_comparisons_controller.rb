module Api
  module V1
    class DriftComparisonsController < BaseController
      def create
        body = payload
        repository = body.fetch("repository")
        baseline_name = body.fetch("baseline_environment")
        target_name = body.fetch("target_environment")

        return unless authorize_integration!(
          permission: "read", repository: repository, environment: baseline_name
        )
        return unless authorize_integration!(
          permission: "read", repository: repository, environment: target_name
        )

        application = current_organization.applications.find_by!(
          repository_full_name: repository
        )
        comparison = Drift::Comparator.new.call(
          application: application,
          baseline_name: baseline_name,
          target_name: target_name,
          mode: body.fetch("mode", "reported")
        )
        render json: represent(comparison), status: :created
      end

      def show
        comparison = current_organization.drift_comparisons.find(params[:id])
        return unless authorize_comparison!(comparison)

        render json: represent(comparison)
      end

      def index
        repository = params.require(:repository)
        return unless authorize_integration!(permission: "read", repository: repository)

        application = current_organization.applications.find_by!(
          repository_full_name: repository
        )
        comparisons = current_organization.drift_comparisons
          .where(application: application).order(compared_at: :desc, id: :desc).limit(50)
        comparisons = comparisons.select { |comparison| permitted_comparison?(comparison) }

        render json: { comparisons: comparisons.map { |comparison| represent(comparison) } }
      end

      private

      def permitted_comparison?(comparison)
        current_credential.permits?(permission: "read",
          repository: comparison.application.repository_full_name,
          environment: comparison.baseline_environment.name) &&
          current_credential.permits?(permission: "read",
            repository: comparison.application.repository_full_name,
            environment: comparison.target_environment.name)
      end

      def authorize_comparison!(comparison)
        return true if permitted_comparison?(comparison)

        render json: { error: "Insufficient credential scope" }, status: :forbidden
        false
      end

      def represent(comparison)
        {
          id: comparison.id,
          repository: comparison.application.repository_full_name,
          baseline_environment: comparison.baseline_environment.name,
          target_environment: comparison.target_environment.name,
          compared_at: comparison.compared_at,
          status: comparison.status,
          result: comparison.result
        }
      end

      public

      rescue_from ActiveRecord::RecordNotFound do
        render json: { error: "Comparison or environment not found" }, status: :not_found
      end
    end
  end
end
