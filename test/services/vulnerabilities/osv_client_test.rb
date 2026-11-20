require "test_helper"

module Vulnerabilities
  class OsvClientTest < ActiveSupport::TestCase
    test "queries a versioned PURL" do
      stub_request(:post, OsvClient::API_URL)
        .with do |request|
          JSON.parse(request.body).fetch("queries") == [
            { "package" => { "purl" => "pkg:gem/rack@3.1.0" } }
          ]
        end
        .to_return(status: 200,
          body: '{"results":[{"vulns":[{"id":"GHSA-demo","modified":"2026-01-01T00:00:00Z"}]}]}')

      result = OsvClient.new.query_batch(["pkg:gem/rack@3.1.0"])
      assert_equal "GHSA-demo", result.fetch("pkg:gem/rack@3.1.0").first.fetch("id")
    end

    test "paginates incomplete API results" do
      stub_request(:post, OsvClient::API_URL)
        .to_return(
          { status: 200, body: '{"results":[{"vulns":[{"id":"OSV-1"}],"next_page_token":"next"}]}' },
          { status: 200, body: '{"results":[{"vulns":[{"id":"OSV-2"}]}]}' }
        )
      ids = OsvClient.new.query_batch(["pkg:gem/rack@3.1.0"])
        .fetch("pkg:gem/rack@3.1.0").map { |v| v.fetch("id") }
      assert_equal %w[OSV-1 OSV-2], ids
    end

    test "raises on provider failures instead of returning safe" do
      stub_request(:post, OsvClient::API_URL).to_return(status: 503)
      assert_raises(OsvClient::QueryError) do
        OsvClient.new.query_batch(["pkg:gem/rack@3.1.0"])
      end
    end
  end
end
