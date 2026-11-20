require_relative "boot"
require "rails/all"

Bundler.require(*Rails.groups)

module Deplograph
  class Application < Rails::Application
    config.load_defaults 8.1
    config.time_zone = "UTC"
    config.active_job.queue_adapter = :async
    config.active_record.schema_format = :ruby
    config.generators.system_tests = nil
  end
end
