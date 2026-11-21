require "test_helper"
require "tempfile"
require_relative "../../collectors/lib/deplograph/env_fingerprint_collector"

class EnvFingerprintCollectorTest < ActiveSupport::TestCase
  setup do
    @secret = "a" * 48
    @env = {
      "DATABASE_URL" => "postgres://secret@example/production",
      "FLAG" => "false",
      "DEPLOGRAPH_TOKEN" => "hidden-collector-token"
    }
  end

  test "HMAC is stable, domain-separated by key and repo, and hides original values" do
    Tempfile.create("deplograph-hmac-key") do |key|
      key.binmode
      key.write(@secret)
      key.flush
      create = lambda do |env, repository|
        Deplograph::RuntimeCollectors::EnvFingerprintCollector.new(
          env: env, source: "docker_agent",
          workload: "payments/web", repository: repository,
          key_id: "shared-v1", key_file: key.path
        ).collect
      end
      first = create.call(@env, "acme/payments")
      repeated = create.call(@env, "acme/payments")
      assert_equal first.fetch(:fingerprint_batch).fetch("fingerprints"),
        repeated.fetch(:fingerprint_batch).fetch("fingerprints")

      digests = first.fetch(:fingerprint_batch).fetch("fingerprints")
      assert_equal %w[DATABASE_URL FLAG], digests.keys.sort
      assert_match(/\A[a-f0-9]{64}\z/, digests.fetch("DATABASE_URL"))
      refute_equal digests.fetch("DATABASE_URL"), digests.fetch("FLAG")

      other_repo = create.call(@env, "other/payments")
      refute_equal digests.fetch("DATABASE_URL"),
        other_repo.fetch(:fingerprint_batch).fetch("fingerprints").fetch("DATABASE_URL")

      updated_env = @env.merge("DATABASE_URL" => "postgres://another-value")
      updated = create.call(updated_env, "acme/payments")
      refute_equal digests.fetch("DATABASE_URL"),
        updated.fetch(:fingerprint_batch).fetch("fingerprints").fetch("DATABASE_URL")

      raw = JSON.generate(first)
      refute_includes raw, "postgres://secret"
      refute_includes raw, "hidden-collector-token"
      refute_includes raw, @secret
      assert_equal "partial", first.fetch(:names).fetch("completeness")
    end
  end

  test "publisher posts only names then HMACs, not values or secret keys" do
    Tempfile.create("deplograph-hmac-key") do |key|
      key.binmode
      key.write(@secret)
      key.flush
      collection = Deplograph::RuntimeCollectors::EnvFingerprintCollector.new(
        env: @env, source: "docker_agent", workload: "payments/web",
        repository: "acme/payments", key_id: "shared-v1", key_file: key.path
      ).collect

      first = stub_request(:post, "https://deplograph.example/api/v1/configuration_snapshots")
        .with { |request|
          body = JSON.parse(request.body)
          body.fetch("keys") == %w[DATABASE_URL FLAG] &&
            !request.body.include?("postgres://") &&
            !request.body.include?("hidden-collector-token")
        }.to_return(status: 201, body: '{"id":42}')
      second = stub_request(:post, "https://deplograph.example/api/v1/configuration/fingerprints")
        .with { |request|
          body = JSON.parse(request.body)
          body.fetch("snapshot_id") == 42 &&
            body.fetch("fingerprints").keys.sort == %w[DATABASE_URL FLAG] &&
            body.fetch("fingerprints").values.all? { |v| v.match?(/\A[a-f0-9]{64}\z/) } &&
            !request.body.include?("postgres://") &&
            !request.body.include?(@secret)
        }.to_return(status: 201, body: '{"id":7}')

      uploader = Deplograph::RuntimeCollectors::EnvFingerprintPublisher.new(
        names_url: "https://deplograph.example/api/v1/configuration_snapshots",
        token: "integration-token", repository: "acme/payments",
        environment: "production"
      )
      assert_equal 42, uploader.publish(collection)
      assert_requested first
      assert_requested second
    end
  end

  test "rejects weak local HMAC key without exposing it" do
    Tempfile.create("weak-key") do |key|
      key.write("too-short")
      key.flush
      assert_raises(Deplograph::RuntimeCollectors::Error) do
        Deplograph::RuntimeCollectors::EnvFingerprintCollector.new(
          env: @env, source: "docker_agent", workload: "web",
          repository: "acme/payments", key_id: "shared-v1", key_file: key.path
        )
      end
    end
  end
end
