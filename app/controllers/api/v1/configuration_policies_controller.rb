module Api
  module V1
    class ConfigurationPoliciesController < BaseController
      ALLOWED = %w[
        repository baseline_environment target_environment workload scope name rule
      ].freeze

      rescue_from ActiveRecord::RecordNotFound do
        render json: { error: "Application or environment not found" }, status: :not_found
      end

      def index
        app, baseline, target = scoped_context("read", params)
        return if performed?

        policies = app.configuration_policies.where(
          baseline_environment: baseline, target_environment: target
        ).order(:workload, :scope, :name)
        policies = policies.where(workload: params[:workload]) if params[:workload].present?
        policies = policies.where(scope: params[:scope]) if params[:scope].present?
        render json: {
          policies: policies.limit(500).map { |policy| serialize(policy) }
        }
      end

      def upsert
        body = payload
        unless (body.keys - ALLOWED).empty?
          return render json: { error: "Unsupported policy fields" }, status: :unprocessable_entity
        end

        app, baseline, target = scoped_context("manage", body)
        return if performed?

        policy = Configuration::PolicyRecorder.new.call(
          application: app, baseline_environment: baseline,
          target_environment: target,
          workload: body.fetch("workload"), scope: body.fetch("scope"),
          name: body.fetch("name"), rule: body.fetch("rule"),
          credential: current_credential
        )
        render json: serialize(policy), status: :ok
      end

      private

      def scoped_context(permission, data)
        repository = data.fetch("repository")
        left = data.fetch("baseline_environment")
        right = data.fetch("target_environment")
        return unless authorize_integration!(
          permission: permission, repository: repository, environment: left
        )
        return unless authorize_integration!(
          permission: permission, repository: repository, environment: right
        )

        app = current_organization.applications.find_by!(repository_full_name: repository)
        [app, app.environments.find_by!(name: left), app.environments.find_by!(name: right)]
      end

      def serialize(policy)
        {
          id: policy.id, repository: policy.application.repository_full_name,
          baseline_environment: policy.baseline_environment.name,
          target_environment: policy.target_environment.name,
          name: policy.name, workload: policy.workload,
          scope: policy.scope, rule: policy.rule,
          updated_at: policy.updated_at
        }
      end
    end
  end
end
