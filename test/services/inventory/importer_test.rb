require "test_helper"

module Inventory
  class ImporterTest < ActiveSupport::TestCase
    setup do
      @application = Application.create!(name: "Demo", repository_full_name: "acme/inventory-demo")
    end

    test "imports CycloneDX and dependency relationships" do
      snapshot = import("sample_cyclonedx.json", "cyclonedx")
      assert_equal 3, snapshot.component_occurrences.count
      assert_equal 2, snapshot.dependency_edges.count
      assert_equal %w[actionpack rack rails],
        snapshot.component_occurrences.joins(:component).pluck("components.name").sort
      assert_equal "not_scanned", snapshot.match_status
    end

    test "imports SPDX 2.3 packages and relationships" do
      snapshot = import("sample_spdx.json", "spdx")
      assert_equal 2, snapshot.component_occurrences.count
      assert_equal 1, snapshot.dependency_edges.count
      assert snapshot.component_occurrences.joins(:component)
        .where(components: { purl: "pkg:gem/rack@3.1.0" }).exists?
    end

    test "repeated imports are idempotent" do
      first = import("sample_cyclonedx.json", "cyclonedx")
      second = import("sample_cyclonedx.json", "cyclonedx")
      assert_equal first.id, second.id
      assert_equal 1, InventorySnapshot.count
      assert_equal 3, ComponentOccurrence.count
    end

    test "unsupported format is rejected" do
      assert_raises(Importer::InvalidDocument) do
        Importer.new.call(application: @application,
          artifact_identifier: "git:demo", document: {}, format: "unknown")
      end
    end

    test "missing PURL is not classified as a package match" do
      document = JSON.parse(File.read(Rails.root.join("examples/sample_cyclonedx.json")))
      document["components"].first.delete("purl")
      snapshot = Importer.new.call(application: @application,
        artifact_identifier: "git:demo", document: document, format: "cyclonedx")
      assert_equal 2, snapshot.component_occurrences.count
    end

    private

    def import(filename, format)
      Importer.new.call(application: @application,
        artifact_identifier: "git:demo",
        document: JSON.parse(File.read(Rails.root.join("examples", filename))),
        format: format)
    end
  end
end
