require "test_helper"

class DashboardTest < ActionDispatch::IntegrationTest
  test "dashboard requires sign-in and shows only the current organization's data" do
    organization = create_test_organization
    user = User.create!(email: "owner@example.test", password: "long-test-password")
    Membership.create!(organization: organization, user: user, role: "owner")
    Application.create!(organization: organization, name: "My App", repository_full_name: "acme/my-app")
    other = create_test_organization
    Application.create!(organization: other, name: "Other App", repository_full_name: "acme/other-app")

    get "/"
    assert_redirected_to login_path

    post "/login", params: { email: user.email, password: "long-test-password" }
    assert_redirected_to root_path
    get "/"
    assert_response :success
    assert_select "h1", text: "Deplograph"
    assert_includes response.body, "My App"
    refute_includes response.body, "Other App"

    delete "/logout"
    assert_redirected_to login_path
    get "/"
    assert_redirected_to login_path
  end

  test "health endpoint responds without authentication" do
    get "/up"
    assert_response :success
    assert_equal "ok", response.body
  end
end
