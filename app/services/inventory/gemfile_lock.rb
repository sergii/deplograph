require "bundler"
require "digest"

module Inventory
  class GemfileLock
    class InvalidLockfile < StandardError; end

    MAX_BYTES = 1_000_000
    MAX_SPECS = 20_000

    def call(content)
      raise InvalidLockfile, "Gemfile.lock must be a string" unless content.is_a?(String)
      raise InvalidLockfile, "Gemfile.lock exceeds size limit" if content.bytesize > MAX_BYTES
      raise InvalidLockfile, "Missing GEM section" unless content.include?("GEM\n")

      lock = Bundler::LockfileParser.new(content)
      specs = lock.specs
      raise InvalidLockfile, "Too many locked packages" if specs.length > MAX_SPECS
      raise InvalidLockfile, "No locked packages" if specs.empty?

      # A gem may have platform-specific variants. Dependency edges are emitted
      # only when a dependency name resolves to exactly one version.
      grouped = specs.group_by(&:name)
      refs = {}
      components = specs.map do |spec|
        raise InvalidLockfile, "Invalid gem name" unless spec.name.match?(/\A[a-zA-Z0-9_.-]+\z/)

        ref = "pkg:gem/#{spec.name}@#{spec.version}"
        refs[[spec.name, spec.version.to_s]] = ref
        { "type" => "library", "name" => spec.name, "version" => spec.version.to_s,
          "purl" => ref, "bom-ref" => ref }
      end.uniq { |entry| entry.fetch("bom-ref") }

      dependencies = components.map do |component|
        name = component.fetch("name")
        version = component.fetch("version")
        spec = grouped.fetch(name).find { |entry| entry.version.to_s == version }
        targets = spec.dependencies.filter_map do |dep|
          versions = grouped.fetch(dep.name, []).map { |candidate| candidate.version.to_s }.uniq
          refs[[dep.name, versions.first]] if versions.length == 1
        end.uniq.sort
        { "ref" => component.fetch("bom-ref"), "dependsOn" => targets }
      end

      {
        "bomFormat" => "CycloneDX",
        "specVersion" => "1.6",
        "version" => 1,
        "metadata" => { "tools" => { "components" => [
          { "type" => "application", "name" => "Deplograph lockfile parser" }
        ] } },
        "components" => components.sort_by { |entry| entry.fetch("bom-ref") },
        "dependencies" => dependencies.sort_by { |entry| entry.fetch("ref") }
      }
    rescue Bundler::LockfileError, Bundler::Dsl::DSLError, Gem::Exception => error
      raise InvalidLockfile, "Invalid Gemfile.lock: #{error.class}"
    end
  end
end
