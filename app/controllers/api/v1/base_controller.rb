module Api
  module V1
    class BaseController < ActionController::API
      MAX_PAYLOAD_BYTES = 5 * 1024 * 1024

      before_action :authenticate_ingestion!

      rescue_from JSON::ParserError, with: :invalid_json
      rescue_from KeyError, ArgumentError, Inventory::Importer::InvalidDocument,
                  ActiveRecord::RecordInvalid, with: :unprocessable

      private

      def authenticate_ingestion!
        token = ENV["DEPLOGRAPH_INGEST_TOKEN"]
        if token.blank?
          render json: { error: "Ingestion is not configured" }, status: :service_unavailable
          return
        end

        supplied = request.authorization.to_s.delete_prefix("Bearer ")
        unless supplied.bytesize == token.bytesize &&
               ActiveSupport::SecurityUtils.secure_compare(supplied, token)
          render json: { error: "Unauthorized" }, status: :unauthorized
        end
      end

      def payload
        @payload ||= begin
          body = request.raw_post
          if body.bytesize > MAX_PAYLOAD_BYTES
            raise ArgumentError, "Payload exceeds 5 MB"
          end
          data = JSON.parse(body)
          raise ArgumentError, "Expected a JSON object" unless data.is_a?(Hash)

          data
        end
      end

      def application_for(body)
        full_name = body.fetch("repository")
        raise ArgumentError, "Invalid repository" unless full_name.match?(/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/)

        Application.find_or_create_by!(repository_full_name: full_name) do |app|
          app.name = body["application"].presence || full_name.split("/").last
        end
      end

      def parse_time(value)
        Time.iso8601(value.to_s)
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
