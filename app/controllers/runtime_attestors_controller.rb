class RuntimeAttestorsController < ApplicationController
  layout "operations"

  rescue_from ActiveRecord::RecordNotFound do
    head :not_found
  end

  def index
    @attestors = current_organization.runtime_attestors.includes(
      :application, :environment, :integration_credential, :approved_by
    ).order(created_at: :desc)
    @applications = current_organization.applications.order(:name)
    @credentials = current_organization.integration_credentials.where(provider: "kubernetes")
      .select { |credential| credential.active? && credential.permissions.include?("observe") }
  end

  def create
    return head :forbidden unless can_approve_attestors?

    data = params.permit(:application_id, :environment_id, :integration_credential_id,
      :name, :image_repository, :expected_workloads, :public_key_pem, :resolution_enabled)
    app = current_organization.applications.find(data.require(:application_id))
    environment = app.environments.find(data.require(:environment_id))
    credential = current_organization.integration_credentials.find(data.require(:integration_credential_id))

    pem = data.require(:public_key_pem).to_s.strip
    return head :unprocessable_entity if pem.include?("PRIVATE KEY")

    key = OpenSSL::PKey.read(pem)
    return head :unprocessable_entity unless key.oid == "ED25519"

    attestor = current_organization.runtime_attestors.create!(
      application: app, environment: environment,
      integration_credential: credential, approved_by: current_user,
      name: data.require(:name),
      image_repository: data.require(:image_repository),
      expected_workloads: JSON.parse(data.require(:expected_workloads)),
      public_key_pem: key.public_to_pem,
      resolution_enabled: data[:resolution_enabled] == "1"
    )
    redirect_to runtime_attestors_path, notice: "Attestor ##{attestor.id} registered"
  rescue ActiveRecord::RecordInvalid, OpenSSL::PKey::PKeyError, JSON::ParserError, ActionController::ParameterMissing
    head :unprocessable_entity
  end

  def revoke
    return head :forbidden unless can_approve_attestors?

    attestor = current_organization.runtime_attestors.find(params[:id])
    attestor.update!(revoked_at: Time.current)
    redirect_to runtime_attestors_path, notice: "Attestor revoked"
  end

  private

  def can_approve_attestors?
    %w[owner admin].include?(
      current_user.memberships.find_by(organization_id: current_organization.id)&.role
    )
  end
  helper_method :can_approve_attestors?
end
