module Api
  module V1
    class BaseController < ActionController::API
      MAX_PAYLOAD_BYTES = 5 * 1024 * 1024

      before_action :authenticate_integration!

      rescue_from Artifacts::IdentityConflict, with: :identity_conflict
      rescue_from JSON::ParserError, with: :invalid_json
      rescue_from KeyError, ArgumentError, Inventory::Importer::InvalidDocument,
                  ActiveRecord::RecordInvalid, with: :unprocessable

      private

      attr_reader :current_credential

      def current_organization
        current_credential.organization
      end

      def authenticate_integration!
        @current_credential = IntegrationCredential.authenticate(request.authorization)
        unless @current_credential
          render json: { error: "Missing, revoked or expired integration credential" },
                 status: :unauthorized
          return
        end

        @current_credential.update_column(:last_used_at, Time.current)
      end

      def authorize_integration!(permission:, repository: nil, environment: nil, provider: nil)
        return true if current_credential.permits?(
          permission: permission, repository: repository,
          environment: environment, provider: provider
        )

        render json: { error: "Insufficient credential permissions or scope" }, status: :forbidden
        false
      end

      def payload
        @payload ||= begin
          body = request.raw_post
          raise ArgumentError, "Payload exceeds 5 MB" if body.bytesize > MAX_PAYLOAD_BYTES

          data = JSON.parse(body)
          raise ArgumentError, "Expected a JSON object" unless data.is_a?(Hash)

          data
        end
      end

      def application_for(body)
        full_name = body.fetch("repository")
        unless full_name.is_a?(String) && full_name.match?(/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/)
          raise ArgumentError, "Invalid repository"
        end

        current_organization.applications.find_or_create_by!(repository_full_name: full_name) do |app|
          app.name = body["application"].presence || full_name.split("/").last
        end
      end

      def parse_time(value)
        Time.iso8601(value.to_s)
      end

      def identity_conflict(error)
        render json: { error: error.message }, status: :conflict
      end

      def invalid_json(_error)
        render json: { error: "Invalid JSON" }, status: :unprocessable_entity
      end

      def unprocessable(error)
        render json: { error: error.message }, status: :unprocessable_entity
      end
    end
  end
end
