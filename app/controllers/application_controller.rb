class ApplicationController < ActionController::Base
  before_action :require_login

  helper_method :current_user, :current_organization

  private

  def current_user
    @current_user ||= User.find_by(id: session[:user_id])
  end

  def current_organization
    return unless current_user

    @current_organization ||= current_user.organizations.find_by(id: session[:organization_id])
  end

  def require_login
    redirect_to login_path unless current_user && current_organization
  end
end
