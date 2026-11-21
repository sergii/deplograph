namespace :inventory do
  desc "Schedule due OSV rescans without requiring a new build or SBOM"
  task rescan_due: :environment do
    if ENV["OSV_ENABLED"] != "true"
      abort "Set OSV_ENABLED=true before scheduling a rescan"
    end

    Vulnerabilities::ScanDueSnapshotsJob.perform_now
    puts "Queued due OSV rescans"
  end
end
