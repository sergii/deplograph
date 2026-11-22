class OrganizationsController < ApplicationController
  def select
    membership = current_user.memberships.find_by(organization_id: params[:id])
    return head :forbidden unless membership

    session[:organization_id] = membership.organization_id
    redirect_to root_path
  end
end
