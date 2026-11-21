module Github
  class InstallationsController < ApplicationController
    before_action :require_manager, except: :index

    def index
      @installations = current_organization.github_installations
        .includes(:github_repository_grants).order(:account_login)
    end

    def setup
      @installation_id = params[:installation_id]
      @installation_id = nil unless valid_installation_id?(@installation_id)
    end

    def authorize
      return head :service_unavailable unless AppClient.configured?

      id = params[:installation_id]
      return head :unprocessable_entity unless valid_installation_id?(id)

      state = SecureRandom.hex(32)
      session[:github_connect] = {
        "installation_id" => id.to_s,
        "organization_id" => current_organization.id,
        "state" => state,
        "created_at" => Time.current.to_i
      }
      url = OauthClient.authorization_url(
        state: state, callback_url: github_installation_callback_url
      )
      redirect_to url, allow_other_host: true
    end

    def callback
      pending = session.delete(:github_connect)
      unless pending.is_a?(Hash) &&
             pending["organization_id"] == current_organization.id &&
             pending["created_at"].to_i >= 10.minutes.ago.to_i &&
             pending["state"].is_a?(String) &&
             params[:state].to_s.bytesize == pending["state"].bytesize &&
             ActiveSupport::SecurityUtils.secure_compare(params[:state].to_s, pending["state"])
        return head :forbidden
      end

      return head :service_unavailable unless AppClient.configured?
      oauth = OauthClient.new
      user_token = oauth.exchange(
        code: params.require(:code), callback_url: github_installation_callback_url
      )
      authorized = oauth.installations(user_token: user_token)
      installation = InstallationLinker.new.call(
        organization: current_organization, user: current_user,
        installation_id: pending.fetch("installation_id"), authorized_installations: authorized
      )

      redirect_to github_installations_path,
        notice: "Linked GitHub installation for #{installation.account_login}"
    rescue OauthClient::Error, HttpClient::Error
      head :bad_gateway
    rescue InstallationLinker::Forbidden
      head :forbidden
    rescue InstallationLinker::Conflict
      head :conflict
    end

    def sync
      installation = current_organization.github_installations.find_by!(
        installation_id: params.require(:installation_id)
      )
      count = RepositorySynchronizer.new.call(installation: installation)
      redirect_to github_installations_path, notice: "Synchronized #{count} repositories"
    rescue RepositorySynchronizer::PermissionError
      head :forbidden
    rescue HttpClient::Error
      head :bad_gateway
    end

    private

    def require_manager
      membership = current_user.memberships.find_by(organization_id: current_organization.id)
      head :forbidden unless membership&.role.in?(%w[owner admin])
    end

    def valid_installation_id?(id)
      id.to_s.match?(/\A[1-9][0-9]{0,17}\z/)
    end
  end
end
