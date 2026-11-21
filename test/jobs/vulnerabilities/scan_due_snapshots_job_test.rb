require "test_helper"

module Vulnerabilities
  class ScanDueSnapshotsJobTest < ActiveSupport::TestCase
    setup do
      @old_enabled = ENV["OSV_ENABLED"]
      ENV["OSV_ENABLED"] = "true"
      app = Application.create!(
        organization: create_test_organization, name: "Demo",
        repository_full_name: "acme/rescan-demo"
      )
      @snapshot = Inventory::LockfileImporter.new.call(
        application: app,
        content: File.read(Rails.root.join("examples/scenarios/rails-lockfile/Gemfile.lock"))
      )
    end

    teardown do
      ENV["OSV_ENABLED"] = @old_enabled
    end

    test "queues old inventory even when no commit or deployment has changed" do
      @snapshot.update!(match_status: "completed", match_completed_at: 2.days.ago)
      assert_enqueued_jobs 1, only: MatchSnapshotJob do
        ScanDueSnapshotsJob.perform_now
      end
      assert_equal 0, Deployment.count
    end

    test "does not queue recently scanned or already running inventory" do
      @snapshot.update!(match_status: "completed", match_completed_at: 1.minute.ago)
      assert_no_enqueued_jobs only: MatchSnapshotJob do
        ScanDueSnapshotsJob.perform_now
      end

      @snapshot.update!(match_status: "running", match_completed_at: 2.days.ago)
      assert_no_enqueued_jobs only: MatchSnapshotJob do
        ScanDueSnapshotsJob.perform_now
      end
    end

    test "disabled OSV scanning cannot enqueue network work" do
      ENV["OSV_ENABLED"] = "false"
      assert_no_enqueued_jobs only: MatchSnapshotJob do
        ScanDueSnapshotsJob.perform_now
      end
    end
  end
end
