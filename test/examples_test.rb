require "test_helper"

class ExamplesTest < ActiveSupport::TestCase
  test "example JSON documents parse" do
    Dir[Rails.root.join("examples/*.json")].each do |path|
      assert_kind_of Hash, JSON.parse(File.read(path))
    end
  end
end
