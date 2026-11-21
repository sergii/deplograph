require "test_helper"
require "yaml"

class OpenapiTest < ActiveSupport::TestCase
  EXPECTED = {
    "/api/v1/inventories" => { "post" => "201" },
    "/api/v1/inventories/lockfile" => { "post" => "201" },
    "/api/v1/drift/comparisons" => { "post" => "201", "get" => "200" },
    "/api/v1/configuration_snapshots" => { "post" => "201", "get" => "200" },
    "/api/v1/configuration/drift" => { "post" => "201" },
    "/api/v1/configuration/fingerprints" => { "post" => "201" },
    "/api/v1/configuration/fingerprints/drift" => { "post" => "201" },
    "/api/v1/configuration/policies" => { "get" => "200", "put" => "200" },
    "/api/v1/releases" => { "get" => "200", "post" => "201" },
    "/api/v1/deployments" => { "post" => "201" },
    "/api/v1/integration_events" => { "post" => "202" },
    "/api/v1/environments" => { "get" => "200" },
    "/api/v1/environment_events" => { "post" => "201" },
    "/api/v1/repositories/inspect" => { "post" => "200" },
    "/api/v1/github/webhooks" => { "post" => "202" }
  }.freeze

  test "OpenAPI describes implemented routes and response statuses" do
    spec = YAML.safe_load_file(Rails.root.join("public/openapi.yaml"))
    assert_equal "3.1.0", spec.fetch("openapi")
    assert_equal "http", spec.dig("components", "securitySchemes", "IntegrationCredential", "type")
    EXPECTED.each do |path, methods|
      methods.each do |method, status|
        operation = spec.fetch("paths").fetch(path).fetch(method)
        assert operation.fetch("responses").key?(status), "#{method.upcase} #{path} lacks #{status}"
        assert operation.key?("operationId"), "#{method.upcase} #{path} needs operationId"
        assert Rails.application.routes.recognize_path(path, method: method.to_sym),
          "Missing Rails route #{method.upcase} #{path}"
        if path != "/api/v1/github/webhooks"
          assert spec.fetch("security").any?
        else
          assert_equal [], operation.fetch("security")
        end
      end
    end
  end

  test "drift comparison by-id API has an OpenAPI path and a real Rails route" do
    spec = YAML.safe_load_file(Rails.root.join("public/openapi.yaml"))
    assert spec.dig("paths", "/api/v1/drift/comparisons/{id}", "get", "responses").key?("200")
    route = Rails.application.routes.recognize_path(
      "/api/v1/drift/comparisons/42", method: :get
    )
    assert_equal "drift_comparisons", route.fetch(:controller).split("/").last
    assert_equal "show", route.fetch(:action)
  end

  test "OpenAPI JSON response envelopes declare required keys" do
    spec = YAML.safe_load_file(Rails.root.join("public/openapi.yaml"))
    %w[/api/v1/inventories /api/v1/releases /api/v1/integration_events /api/v1/environments].each do |path|
      method = path == "/api/v1/environments" ? "get" : "post"
      status = { "/api/v1/inventories" => "201", "/api/v1/releases" => "201",
                 "/api/v1/integration_events" => "202", "/api/v1/environments" => "200" }.fetch(path)
      required = spec.dig("paths", path, method, "responses", status, "content",
                          "application/json", "schema", "required")
      assert required.is_a?(Array) && required.any?, "#{path} must declare required keys"
    end
  end
end
