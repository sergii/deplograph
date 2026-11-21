require "test_helper"
require "tempfile"
require_relative "../../collectors/lib/deplograph/kubernetes_control_plane_attestor"

class KubernetesControlPlaneAttestorTest < ActiveSupport::TestCase
  COLLECTOR = Deplograph::RuntimeCollectors
  DIGEST = "sha256:" + "c" * 64

  test "reads live control-plane generation, RS ownership, ready pods and registry digests" do
    source = fake_control_plane

    result = collector(source).collect
    assert_equal "ghcr.io/acme/payments", result.fetch("image_repository")
    assert_equal DIGEST, result.fetch("image_digest")
    assert_equal %w[web worker], result.fetch("workloads").map { |item| item.fetch("name") }
    assert_equal [2, 1], result.fetch("workloads").map { |item| item.fetch("ready_replicas") }
    assert_equal 3, result.fetch("workloads").sum { |item| item.fetch("replicas").size }
    refute_includes JSON.generate(result), "unrelated-secret"
    refute_includes JSON.generate(result), "kubernetes-service-account-token"
    assert_equal result, collector(source).collect
  end

  test "fails closed for partial rollouts and unready containers" do
    source = fake_control_plane
    source.fetch(:deployments).fetch("web").fetch("status")["updatedReplicas"] = 1
    assert_raises(COLLECTOR::Error) { collector(source).collect }

    source = fake_control_plane
    source.fetch(:pods).first.fetch("status").fetch("containerStatuses").first["ready"] = false
    assert_raises(COLLECTOR::Error) { collector(source).collect }
  end

  test "rejects mixed digest and unknown or terminating replicas" do
    source = fake_control_plane
    source.fetch(:pods).first.fetch("status").fetch("containerStatuses").first["imageID"] =
      "ghcr.io/acme/payments@sha256:" + "d" * 64
    assert_raises(COLLECTOR::Error) { collector(source).collect }

    source = fake_control_plane
    source.fetch(:pods) << Marshal.load(Marshal.dump(source.fetch(:pods).first)).tap do |pod|
      pod.fetch("metadata")["uid"] = "rogue-pod"
    end
    assert_raises(COLLECTOR::Error) { collector(source).collect }

    source = fake_control_plane
    source.fetch(:pods).first.fetch("metadata")["deletionTimestamp"] = "2026-11-21T18:00:00Z"
    assert_raises(COLLECTOR::Error) { collector(source).collect }
  end

  test "rejects ReplicaSets or Pods not owned by expected deployment" do
    source = fake_control_plane
    source.fetch(:replica_sets).first.fetch("metadata").fetch("ownerReferences").first["uid"] = "wrong"
    assert_raises(COLLECTOR::Error) { collector(source).collect }

    source = fake_control_plane
    source.fetch(:pods).first.fetch("metadata").fetch("ownerReferences").first["uid"] = "wrong"
    assert_raises(COLLECTOR::Error) { collector(source).collect }
  end

  test "signer sends nonce-bound Ed25519 assertion and never transmits signing key" do
    key = OpenSSL::PKey.generate_key("ED25519")
    Tempfile.create("attestation-ed25519") do |file|
      file.binmode
      file.write(key.private_to_pem)
      file.flush

      result = collector(fake_control_plane).collect
      challenge_request = stub_request(:post,
        "https://deplograph.example/api/v1/runtime/attestation_challenges")
        .with { |request|
          parsed = JSON.parse(request.body)
          parsed.fetch("attestor_id") == 3 &&
            request.headers.fetch("Authorization") == "Bearer scoped-token"
        }.to_return(status: 201, body: JSON.generate(
          "attestor_id" => 3, "nonce" => "a" * 64,
          "expires_at" => Time.now.utc.iso8601
        ))
      signed_request = stub_request(:post,
        "https://deplograph.example/api/v1/runtime/attestations")
        .with { |request|
          parsed = JSON.parse(request.body)
          assertion = parsed.fetch("attestation")
          signature = Base64.strict_decode64(parsed.fetch("signature"))
          key.public_key.verify(nil, signature,
            JSON.generate(deep_sort(assertion))) &&
            assertion.fetch("nonce") == "a" * 64 &&
            assertion.fetch("workloads").size == 2 &&
            !request.body.include?("PRIVATE KEY")
        }.to_return(status: 201, body: JSON.generate(
          "id" => 12, "complete" => true, "signature_verified" => true,
          "ready_replicas" => 3, "resolutions" => [9]
        ))
      publisher = COLLECTOR::SignedAttestationPublisher.new(
        url: "https://deplograph.example/api/v1/runtime/attestations",
        token: "scoped-token", private_key_file: file.path,
        attestor_id: 3, repository: "acme/payments", environment: "production"
      )
      answer = publisher.publish(result)
      assert_equal 12, answer.fetch("id")
      assert_requested challenge_request
      assert_requested signed_request
    end
  end

  private

  def collector(source)
    clock = -> { Time.utc(2026, 11, 21, 18, 0) }
    COLLECTOR::KubernetesControlPlaneAttestor.new(
      namespace: "production", client: source.fetch(:api),
      expected_workloads: { "web" => 2, "worker" => 1 },
      image_repository: "ghcr.io/acme/payments", clock: clock
    )
  end

  def deep_sort(value)
    case value
    when Hash
      value.keys.sort.to_h { |key| [key, deep_sort(value.fetch(key))] }
    when Array
      value.map { |item| deep_sort(item) }
    else
      value
    end
  end

  def fake_control_plane
    deployments = {}
    replica_sets = []
    pods = []
    { "web" => 2, "worker" => 1 }.each do |name, count|
      deployments[name] = {
        "metadata" => { "uid" => "deployment-#{name}", "generation" => 4 },
        "spec" => {
          "selector" => { "matchLabels" => { "component" => name } },
          "replicas" => count, "paused" => false,
          "template" => { "spec" => { "containers" => [
            { "name" => name, "image" => "ghcr.io/acme/payments:release-2" }
          ] } }
        },
        "status" => {
          "observedGeneration" => 4, "replicas" => count,
          "readyReplicas" => count, "updatedReplicas" => count, "availableReplicas" => count
        }
      }
      replica_sets << { "metadata" => {
        "uid" => "rs-#{name}",
        "ownerReferences" => [
          { "uid" => "deployment-#{name}", "controller" => true }
        ]
      } }
      count.times do |index|
        pods << {
          "metadata" => {
            "uid" => "pod-#{name}-#{index}",
            "labels" => { "component" => name },
            "ownerReferences" => [{ "uid" => "rs-#{name}", "controller" => true }]
          },
          "status" => {
            "phase" => "Running",
            "containerStatuses" => [{
              "name" => name, "ready" => true,
              "state" => { "running" => {} },
              "imageID" => "ghcr.io/acme/payments@#{DIGEST}"
            }]
          },
          "spec" => { "containers" => [
            { "name" => name, "env" => [{ "name" => "SECRET", "value" => "unrelated-secret" }] }
          ] }
        }
      end
    end
    api = Object.new
    api.define_singleton_method(:deployment) { |_ns, name| deployments.fetch(name) }
    api.define_singleton_method(:replica_sets) { |_ns| replica_sets }
    api.define_singleton_method(:pods) { |_ns| pods }
    { api: api, deployments: deployments, replica_sets: replica_sets, pods: pods }
  end
end
