require "test_helper"
require "tempfile"
require_relative "../../collectors/lib/deplograph/kubernetes_collector"
require_relative "../../collectors/lib/deplograph/kamal_collector"

class RuntimeCollectorsTest < ActiveSupport::TestCase
  Collector = Deplograph::RuntimeCollectors
  DIGEST_A = "sha256:" + "a" * 64
  DIGEST_B = "sha256:" + "b" * 64

  test "Kubernetes reads running container image IDs, not desired PodSpec tags" do
    pod = {
      "metadata" => { "uid" => "uuid-1", "name" => "payments-78b9b9", "labels" => {
        "app.kubernetes.io/name" => "payments"
      } },
      "spec" => { "containers" => [{ "name" => "web", "image" => "ghcr.io/acme/payments:latest",
                                      "env" => [{ "name" => "SECRET", "value" => "dont-send-me" }] }] },
      "status" => { "phase" => "Running", "containerStatuses" => [
        { "name" => "web", "imageID" => "docker-pullable://ghcr.io/acme/payments@#{DIGEST_A}",
          "containerID" => "containerd://unique-1", "state" => { "running" => { "startedAt" => "now" } } },
        { "name" => "init", "imageID" => "containerd://#{DIGEST_B}",
          "state" => { "running" => {} } }
      ] }
    }
    api = Object.new
    api.define_singleton_method(:list_pods) { |_namespace| [pod] }

    collector = Collector::KubernetesCollector.new(namespace: "payments", client: api,
      clock: -> { Time.utc(2026, 11, 21, 14, 0, 0) })
    events = collector.collect
    assert_equal 1, events.length
    event = events.first
    assert_equal "kubernetes", event.fetch("source")
    assert_equal DIGEST_A, event.fetch("image_digest")
    assert_equal "oci:ghcr.io/acme/payments@#{DIGEST_A}", event.fetch("artifact_identifier")
    assert_equal "payments-78b9b9", event.fetch("workload").split("/")[1]
    assert_equal "payments/web", event.dig("metadata", "logical_workload")
    assert_equal "partial", event.dig("metadata", "coverage")
    refute_includes JSON.generate(event), "dont-send-me"
    assert_equal events, collector.collect
  end

  test "Kubernetes skips non-running pods and unresolvable imageIDs" do
    pod = {
      "metadata" => { "uid" => "u-2", "name" => "demo" },
      "status" => { "phase" => "Pending", "containerStatuses" => [
        { "name" => "web", "imageID" => "ghcr.io/acme/demo@#{DIGEST_A}",
          "state" => { "running" => {} } }
      ] }
    }
    client = Object.new
    client.define_singleton_method(:list_pods) { |ns| [pod] }
    assert_empty Collector::KubernetesCollector.new(namespace: "default", client: client).collect
  end

  test "Kamal rejects Docker image IDs and only uses unique registry RepoDigests" do
    id = "c" * 64
    image_id = "sha256:" + "d" * 64
    docker = Object.new
    docker.define_singleton_method(:list) { |service:| [id] }
    docker.define_singleton_method(:container) do |_id|
      { "Id" => id, "Image" => image_id,
        "State" => { "Running" => true },
        "Config" => { "Image" => "ghcr.io/acme/payments:latest",
          "Labels" => { "service" => "payments", "role" => "web", "destination" => "production",
                        "untrusted_env" => "secret-do-not-send" } } }
    end
    repo_digests = ["ghcr.io/acme/payments@#{DIGEST_A}"]
    docker.define_singleton_method(:image) { |_id| { "RepoDigests" => repo_digests } }

    collector = Collector::KamalCollector.new(
      service: "payments", image_repository: "ghcr.io/acme/payments",
      destination: "production", host_id: "host-1", docker: docker,
      clock: -> { Time.utc(2026, 11, 21, 14, 0, 0) }
    )
    events = collector.collect
    assert_equal 1, events.size
    assert_equal DIGEST_A, events.first.fetch("image_digest")
    assert_equal "payments/web", events.first.dig("metadata", "logical_workload")
    assert_equal "kamal_agent", events.first.fetch("source")
    refute_includes JSON.generate(events), "secret-do-not-send"

    repo_digests.replace([])
    assert_empty collector.collect
    repo_digests.replace(["ghcr.io/acme/payments@#{DIGEST_A}", "ghcr.io/acme/payments@#{DIGEST_B}"])
    assert_empty collector.collect
  end

  test "Kubernetes list Pods uses service account over TLS and supports pagination" do
    Tempfile.create("kubernetes-token") do |token_file|
      token_file.write("k8s-service-account")
      token_file.flush
      first = stub_request(:get, %r{\Ahttps://kubernetes.default.svc/api/v1/namespaces/staging/pods\?})
        .with(headers: { "Authorization" => "Bearer k8s-service-account" })
        .to_return(
          { status: 200, body: JSON.generate("metadata" => { "continue" => "next" },
                                             "items" => [{ "metadata" => { "name" => "one" } }]) },
          { status: 200, body: JSON.generate("metadata" => { "continue" => "" },
                                             "items" => [{ "metadata" => { "name" => "two" } }]) }
        )
      api = Collector::KubernetesApi.new(host: "kubernetes.default.svc",
        token_file: token_file.path, ca_file: "/etc/ssl/certs/ca-certificates.crt",
        selector: "app=payments")
      pods = api.list_pods("staging")
      assert_equal %w[one two], pods.map { |p| p.fetch("metadata").fetch("name") }
      assert_requested first, times: 2
    end
  end

  test "runtime observer rejects unsafe URLs and only transmits events via HTTPS" do
    assert_raises(Collector::Error) do
      Collector::Emitter.new(url: "http://insecure.example/api/v1/integration_events",
        token: "secret", repository: "acme/demo", environment: "production")
    end
    assert_raises(Collector::Error) do
      Collector::Emitter.new(url: "https://example.com/other",
        token: "secret", repository: "acme/demo", environment: "production")
    end

    call = stub_request(:post, "https://deplograph.example/api/v1/integration_events")
      .with(headers: { "Authorization" => "Bearer scoped-observer-token" })
      .to_return(status: 202, body: "{}")
    client = Collector::Emitter.new(url: "https://deplograph.example/api/v1/integration_events",
      token: "scoped-observer-token", repository: "acme/demo", environment: "staging")
    event = {
      "source" => "kubernetes", "event_id" => "k8s:one",
      "occurred_at" => Time.now.utc.iso8601, "workload" => "staging/pod/web",
      "image" => "ghcr.io/acme/demo", "image_digest" => DIGEST_A
    }
    assert client.send_event(event)
    assert_requested call
  end
end
