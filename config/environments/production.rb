Rails.application.configure do
  raise "QUEUE_DATABASE_URL must be configured for the durable worker" if
    ENV["QUEUE_DATABASE_URL"].blank?
  config.enable_reloading = false
  config.eager_load = true
  config.consider_all_requests_local = false
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")
  config.active_support.report_deprecations = false
  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }
  config.active_storage.service = :local
  config.require_master_key = false
end
