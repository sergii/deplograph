require "test_helper"

class DashboardTest < ActionDispatch::IntegrationTest
  test "dashboard loads without any application records" do
    get "/"
    assert_response :success
    assert_select "h1", text: "Deplograph"
  end

  test "health endpoint responds" do
    get "/up"
    assert_response :success
    assert_equal "ok", response.body
  end
end
