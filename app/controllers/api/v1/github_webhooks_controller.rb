require "openssl"
require "json"

module Api
  module V1
    class GithubWebhooksController < ActionController::API
      MAX_BYTES = 2 * 1024 * 1024

      def create
        secret = ENV["GITHUB_WEBHOOK_SECRET"]
        return head :service_unavailable if secret.blank?

        raw = request.raw_post
        return head :request_entity_too_large if raw.bytesize > MAX_BYTES

        signature = request.headers["X-Hub-Signature-256"].to_s
        expected = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", secret, raw)}"
        unless signature.bytesize == expected.bytesize &&
               ActiveSupport::SecurityUtils.secure_compare(signature, expected)
          return head :unauthorized
        end

        body = JSON.parse(raw)
        result = Github::WebhookProcessor.new.call(request.headers["X-GitHub-Event"].to_s, body)
        render json: result, status: :accepted
      rescue JSON::ParserError, KeyError, ArgumentError, ActiveRecord::RecordInvalid
        render json: { error: "Invalid webhook payload" }, status: :unprocessable_entity
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Unknown installation" }, status: :not_found
      end
    end
  end
end
