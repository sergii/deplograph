require "digest"

module Github
  class RepositoryInspector
    def initialize(client: ApiClient.new)
      @client = client
    end

    def call(full_name)
      repository = @client.repository(full_name)
      raise ApiClient::ApiError, "Repository not found" unless repository

      ref = repository.fetch("default_branch")
      inspected_files = {}
      ApiClient::ALLOWED_FILES.each do |path|
        text = @client.file(full_name, path, ref: ref)
        next unless text

        entry = {
          sha256: Digest::SHA256.hexdigest(text), bytes: text.bytesize
        }
        entry[:ruby_version] = text.strip if path == ".ruby-version"
        entry[:base_images] = text.scan(/^\s*FROM\s+(?:--platform=\S+\s+)?(\S+)/i).flatten if path == "Dockerfile"
        if path == "Gemfile.lock"
          entry[:package_count] = text.scan(/^    [^\s(]+ \([^)]+\)/).length
        end
        inspected_files[path] = entry
      end

      {
        repository: full_name,
        default_branch: ref,
        private: repository.fetch("private", false),
        archived: repository.fetch("archived", false),
        inspected_files: inspected_files,
        inspected_at: Time.current.iso8601
      }
    end
  end
end
