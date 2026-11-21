require "test_helper"

class SessionsTest < ActionDispatch::IntegrationTest
  setup do
    @organization = create_test_organization
    @other = create_test_organization
    @user = User.create!(email: "User@Example.TEST", password: "strong-test-password")
    Membership.create!(organization: @organization, user: @user, role: "owner")
    Membership.create!(organization: @other, user: @user, role: "viewer")
  end

  test "login requires a valid password and selects only a member organization" do
    post "/login", params: { email: @user.email, password: "incorrect" }
    assert_response :unprocessable_entity

    get "/"
    assert_redirected_to login_path

    post "/login", params: { email: "user@example.test", password: "strong-test-password" }
    assert_redirected_to root_path

    get "/"
    assert_response :success
    assert_includes response.body, @organization.name

    post select_organization_path(@other)
    assert_redirected_to root_path
    get "/"
    assert_includes response.body, @other.name
  end

  test "cannot switch to an organization without membership" do
    unauthorized = create_test_organization
    post "/login", params: { email: @user.email, password: "strong-test-password" }
    assert_redirected_to root_path

    post select_organization_path(unauthorized)
    assert_response :forbidden
    get "/"
    assert_includes response.body, @organization.name
    refute_includes response.body, unauthorized.name
  end

  test "sign out revokes the browser session" do
    post "/login", params: { email: @user.email, password: "strong-test-password" }
    assert_redirected_to root_path
    delete "/logout"
    assert_redirected_to login_path
    get "/"
    assert_redirected_to login_path
  end
end
