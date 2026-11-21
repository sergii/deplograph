require "test_helper"

module Inventory
  class GemfileLockTest < ActiveSupport::TestCase
    setup do
      @organization = create_test_organization
      @application = Application.create!(
        organization: @organization, name: "Demo", repository_full_name: "acme/ruby-demo"
      )
      @lockfile = File.read(Rails.root.join("examples/scenarios/rails-lockfile/Gemfile.lock"))
    end

    test "turns locked Ruby gems into CycloneDX components and dependency graph" do
      document = GemfileLock.new.call(@lockfile)
      assert_equal "CycloneDX", document.fetch("bomFormat")
      assert_equal 3, document.fetch("components").size
      assert_equal %w[actionpack rack rails],
        document.fetch("components").map { |component| component.fetch("name") }.sort
      rails = document.fetch("dependencies").find { |node| node["ref"] == "pkg:gem/rails@8.1.4" }
      assert_equal ["pkg:gem/actionpack@8.1.4"], rails.fetch("dependsOn")
      actionpack = document.fetch("dependencies").find { |node| node["ref"] == "pkg:gem/actionpack@8.1.4" }
      assert_equal ["pkg:gem/rack@3.1.0"], actionpack.fetch("dependsOn")
    end

    test "imports lockfile with explicitly partial coverage and stable immutable snapshot" do
      service = LockfileImporter.new
      first = service.call(application: @application, content: @lockfile)
      second = service.call(application: @application, content: @lockfile)

      assert_equal first.id, second.id
      assert_equal "partial", first.coverage_status
      assert_equal "Gemfile.lock", first.manifest_type
      assert_equal 3, first.component_occurrences.count
      assert_equal 2, first.dependency_edges.count
      assert_equal "not_scanned", first.match_status
      assert_equal 1, InventorySnapshot.count

      updated = @lockfile.sub("rack (3.1.0)", "rack (3.2.0)")
      newer = service.call(application: @application, content: updated)
      assert_not_equal first.id, newer.id
      assert_equal 2, InventorySnapshot.count
      assert first.artifact.identifier.start_with?("lockfile:sha256:")
    end

    test "invalid lockfiles and excessive payloads fail closed" do
      assert_raises(GemfileLock::InvalidLockfile) { GemfileLock.new.call("not a Gemfile.lock") }
      assert_raises(GemfileLock::InvalidLockfile) { GemfileLock.new.call("x" * 1_000_001) }
      assert_equal 0, InventorySnapshot.count
    end
  end
end
