module Api
  module V1
    class ConfigurationSnapshotsController < BaseController
      rescue_from Configuration::SnapshotRecorder::InvalidSnapshot, with: :invalid_snapshot
      rescue_from Configuration::SnapshotRecorder::Conflict, with: :conflict
      rescue_from ActiveRecord::RecordNotFound do
        render json: { error: "Application or environment not found" }, status: :not_found
      end

      ALLOWED_FIELDS = %w[
        repository environment source scope workload collection_id
        completeness collected_at keys
      ].freeze

      def create
        body = payload
        raise Configuration::SnapshotRecorder::InvalidSnapshot,
          "Unsupported fields; ENV values are never accepted" if (body.keys - ALLOWED_FIELDS).any?

        scope = body.fetch("scope")
        permission = scope == "declared" ? "report" : "observe"
        return unless authorize_integration!(
          permission: permission, repository: body["repository"],
          environment: body["environment"], provider: body["source"]
        )

        snapshot = ApplicationRecord.transaction do
          application = application_for(body)
          environment = application.environments.find_or_create_by!(
            name: body.fetch("environment")
          ) do |record|
            record.kind = if %w[production staging development test preview].include?(record.name)
              record.name
            else
              "other"
            end
          end
          Configuration::SnapshotRecorder.new.call(
            environment: environment, source: body.fetch("source"),
            scope: scope, workload: body.fetch("workload"),
            collection_id: body.fetch("collection_id"),
            completeness: body.fetch("completeness"),
            collected_at: body.fetch("collected_at"), keys: body.fetch("keys")
          )
        end
        render json: {
          id: snapshot.id, environment: snapshot.environment.name,
          workload: snapshot.workload, scope: snapshot.scope,
          completeness: snapshot.completeness, collected_at: snapshot.collected_at,
          key_count: snapshot.configuration_entries.count,
          keys_sha256: snapshot.keys_sha256
        }, status: :created
      end

      def index
        repo = params.require(:repository)
        name = params.require(:environment)
        return unless authorize_integration!(
          permission: "read", repository: repo, environment: name
        )

        app = current_organization.applications.find_by!(repository_full_name: repo)
        environment = app.environments.find_by!(name: name)
        relation = environment.configuration_snapshots.order(collected_at: :desc, id: :desc)
        relation = relation.where(workload: params[:workload]) if params[:workload].present?
        relation = relation.where(scope: params[:scope]) if params[:scope].present?

        render json: { snapshots: relation.limit(50).map do |snapshot|
          {
            id: snapshot.id, scope: snapshot.scope, workload: snapshot.workload,
            source: snapshot.source, completeness: snapshot.completeness,
            collected_at: snapshot.collected_at,
            keys_sha256: snapshot.keys_sha256,
            keys: snapshot.configuration_entries.pluck(:name).sort
          }
        end }
      end

      private

      def invalid_snapshot(error)
        render json: { error: error.message }, status: :unprocessable_entity
      end

      def conflict(error)
        render json: { error: error.message }, status: :conflict
      end
    end
  end
end
