module Api
  module V1
    class EnvironmentsController < BaseController
      def index
        repository = params.require(:repository)
        return unless authorize_integration!(permission: "read", repository: repository)
        application = current_organization.applications.find_by!(repository_full_name: repository)
        render json: {
          repository: repository,
          environments: Exposure::EnvironmentSummary.new.call(application)
        }
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Repository not found" }, status: :not_found
      end
    end
  end
end
