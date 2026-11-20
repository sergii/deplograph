module Api
  module V1
    class EnvironmentsController < BaseController
      def index
        repository = params.require(:repository)
        application = Application.find_by!(repository_full_name: repository)
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
