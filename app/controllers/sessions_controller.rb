class SessionsController < ApplicationController
  skip_before_action :require_login, only: %i[new create]

  def new
    redirect_to root_path if current_user && current_organization
  end

  def create
    user = User.find_by(email: params[:email].to_s.strip.downcase)
    user = user&.authenticate(params[:password].to_s)
    membership = user&.memberships&.order(:id)&.first

    unless user && membership
      flash.now[:alert] = "Invalid credentials or no organization membership"
      render :new, status: :unprocessable_entity
      return
    end

    reset_session
    session[:user_id] = user.id
    session[:organization_id] = membership.organization_id
    redirect_to root_path
  end

  def destroy
    reset_session
    redirect_to login_path
  end
end
