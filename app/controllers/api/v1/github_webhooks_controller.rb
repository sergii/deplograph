require "openssl"
require "json"
require "digest"

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

        delivery_id = request.headers["X-GitHub-Delivery"].to_s
        unless delivery_id.match?(/\A[0-9a-fA-F-]{36}\z/)
          return render json: { error: "Missing GitHub delivery ID" }, status: :unprocessable_entity
        end

        event_name = request.headers["X-GitHub-Event"].to_s
        digest = Digest::SHA256.hexdigest(raw)
        payload = JSON.parse(raw)
        raise ArgumentError, "Expected JSON object" unless payload.is_a?(Hash)

        result = GithubWebhookDelivery.transaction do
          previous = GithubWebhookDelivery.find_by(delivery_id: delivery_id)
          if previous
            if previous.payload_sha256 != digest || previous.event != event_name
              raise ArgumentError, "Conflicting GitHub delivery ID"
            end
            next { duplicate: true }
          end

          GithubWebhookDelivery.create!(
            delivery_id: delivery_id, event: event_name,
            payload_sha256: digest, received_at: Time.current
          )
          Github::WebhookProcessor.new.call(event_name, payload)
        end

        if result[:sync_repository_ids].present?
          Array(result[:sync_repository_ids]).each do |repo_id|
            Github::SyncRepositoryJob.perform_later(
              installation_id: result.fetch(:installation_id), repository_id: repo_id
            )
          end
        end
        render json: result.except(:sync_repository_ids), status: :accepted
      rescue JSON::ParserError, KeyError, ArgumentError, ActiveRecord::RecordInvalid
        render json: { error: "Invalid webhook payload" }, status: :unprocessable_entity
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Unknown installation" }, status: :not_found
      end
    end
  end
end
