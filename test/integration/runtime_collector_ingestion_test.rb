require "test_helper"
require_relative "../../collectors/lib/deplograph/kubernetes_collector"

class RuntimeCollectorIngestionTest < ActionDispatch::IntegrationTest
  setup do
    @organization = create_test_organization
    @observer = issue_test_token(
      organization: @organization, provider: "kubernetes",
      permissions: %w[observe], repository_scopes: ["acme/payments"],
      environment_scopes: ["staging"]
    )
    @reader = issue_test_token(
      organization: @organization, provider: "api",
      permissions: %w[read], repository_scopes: ["acme/payments"]
    )
  end

  test "ingests independent Kubernetes replica observations without verifying a full rollout" do
    digest = "sha256:" + "a" * 64
    pods = %w[pod-a pod-b].map do |pod_name|
      {
        "metadata" => {
          "name" => pod_name, "uid" => "uid-#{pod_name}",
          "labels" => { "app.kubernetes.io/name" => "payments" }
        },
        "status" => {
          "phase" => "Running",
          "containerStatuses" => [{
            "name" => "web", "imageID" => "ghcr.io/acme/payments@#{digest}",
            "containerID" => "containerd://#{pod_name}",
            "state" => { "running" => {} }
          }]
        }
      }
    end
    api = Object.new
    api.define_singleton_method(:list_pods) { |_namespace| pods }
    observations = Deplograph::RuntimeCollectors::KubernetesCollector.new(
      namespace: "staging", client: api
    ).collect
    assert_equal 2, observations.size

    observations.each do |event|
      post "/api/v1/integration_events",
        params: JSON.generate(event.merge(
          "repository" => "acme/payments", "environment" => "staging",
          "event_type" => "artifact.observed"
        )), headers: bearer_headers(@observer)
      assert_response :accepted
    end

    assert_equal 2, DeploymentObservation.count
    assert_equal 0, Deployment.count
    assert_equal ["payments/web"], DeploymentObservation.all.map { |obs|
      obs.metadata.fetch("logical_workload")
    }.uniq

    get "/api/v1/environments", params: { repository: "acme/payments" },
      headers: bearer_headers(@reader)
    assert_response :success
    env = response.parsed_body.fetch("environments").first
    assert_equal "observations_only", env.fetch("verification_status")
    assert_equal 2, env.fetch("observed").size
    assert_equal [digest], env.fetch("observed").map { |item| item.fetch("image_digest") }.uniq
  end

  test "runtime collector token cannot report a different environment or impersonate CI" do
    digest = "sha256:" + "b" * 64
    body = {
      source: "kubernetes", event_type: "artifact.observed",
      event_id: "obs-1", occurred_at: Time.now.utc.iso8601,
      repository: "acme/payments", environment: "production",
      workload: "prod/web", image_digest: digest, image: "ghcr.io/acme/payments"
    }
    post "/api/v1/integration_events", params: JSON.generate(body),
      headers: bearer_headers(@observer)
    assert_response :forbidden

    body[:environment] = "staging"
    body[:source] = "github_actions"
    post "/api/v1/integration_events", params: JSON.generate(body),
      headers: bearer_headers(@observer)
    assert_response :forbidden
    assert_equal 0, DeploymentObservation.count
  end
end
