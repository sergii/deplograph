require "test_helper"
require "yaml"

class ComposeConfigurationTest < ActiveSupport::TestCase
  test "local environment uses configurable PostgreSQL image and new volume mount" do
    config = YAML.safe_load_file(Rails.root.join("compose.yaml"))
    db = config.fetch("services").fetch("database")
    assert_match(/POSTGRES_IMAGE/, db.fetch("image"))
    assert_includes db.fetch("volumes"), "pgdata:/var/lib/postgresql"
    assert_equal "service_healthy",
      config.fetch("services").fetch("web").fetch("depends_on").fetch("database").fetch("condition")
    assert_equal "127.0.0.1:3000:3000",
      config.fetch("services").fetch("web").fetch("ports").first
  end
end
