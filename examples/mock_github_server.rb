#!/usr/bin/env ruby
# Run with: bundle exec ruby examples/mock_github_server.rb

require "base64"
require "json"
require "webrick"

server = WEBrick::HTTPServer.new(Port: 4567, BindAddress: "127.0.0.1")
server.mount_proc("/") do |request, response|
  path = request.path
  response["Content-Type"] = "application/json"
  if path == "/repos/acme/rails-app"
    response.body = JSON.generate(
      full_name: "acme/rails-app", default_branch: "main",
      private: false, archived: false
    )
  elsif path.start_with?("/repos/acme/rails-app/contents/")
    filename = path.split("/contents/", 2).last
    file = File.expand_path("source_app/#{filename}", __dir__)
    if %w[Dockerfile Gemfile.lock .ruby-version].include?(filename) && File.file?(file)
      content = File.binread(file)
      response.body = JSON.generate(
        type: "file", name: filename, size: content.bytesize,
        content: Base64.strict_encode64(content)
      )
    else
      response.status = 404
      response.body = '{"message":"Not Found"}'
    end
  else
    response.status = 404
    response.body = '{"message":"Not Found"}'
  end
end
trap("INT") { server.shutdown }
puts "Mock GitHub API: http://127.0.0.1:4567"
server.start
