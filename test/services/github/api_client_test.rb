require "test_helper"

module Github
  class ApiClientTest < ActiveSupport::TestCase
    test "only allows safe manifest filenames" do
      stub_request(:get, "https://api.github.com/repos/acme/demo/contents/Dockerfile?ref=main")
        .to_return(status: 200, body: file_json("FROM ruby:4.0.10-slim\n"))
      client = ApiClient.new(token: "mock-token")
      assert_equal "FROM ruby:4.0.10-slim\n", client.file("acme/demo", "Dockerfile", ref: "main")
      assert_raises(ArgumentError) { client.file("acme/demo", ".env", ref: "main") }
    end

    test "inspects metadata without retaining raw manifest contents" do
      stub_request(:get, "https://api.github.com/repos/acme/demo")
        .to_return(status: 200, body: '{"default_branch":"main","private":false,"archived":false}')
      stub_request(:get, %r{https://api.github.com/repos/acme/demo/contents/})
        .to_return(status: 404, body: '{"message":"Not Found"}')
      stub_request(:get, "https://api.github.com/repos/acme/demo/contents/.ruby-version?ref=main")
        .to_return(status: 200, body: file_json("4.0.10\n"))
      stub_request(:get, "https://api.github.com/repos/acme/demo/contents/Dockerfile?ref=main")
        .to_return(status: 200, body: file_json("FROM ruby:4.0.10-slim\n"))
      summary = RepositoryInspector.new(client: ApiClient.new(token: "mock-token")).call("acme/demo")
      assert_equal "main", summary.fetch(:default_branch)
      assert_equal "4.0.10", summary.dig(:inspected_files, ".ruby-version", :ruby_version)
      assert_equal ["ruby:4.0.10-slim"], summary.dig(:inspected_files, "Dockerfile", :base_images)
    end

    private

    def file_json(content)
      JSON.generate(type: "file", size: content.bytesize, content: Base64.strict_encode64(content))
    end
  end
end
