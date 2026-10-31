# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"
require File.expand_path("../../test/dummy/config/environment", __dir__)
require File.expand_path("../../test/test_helper", __dir__)
require "minitest/assertions"
require "rack/test"

module CucumberRackHelpers
  include Rack::Test::Methods

  def app
    Rails.application
  end
end

# ActiveSupport::TestCase aliases refute_nil as assert_not_nil. Cucumber's
# world only includes Minitest::Assertions, so steps that call the Rails
# name need the same alias.
module CucumberAssertionAliases
  def assert_not_nil(object, message = nil)
    refute_nil(object, message)
  end
end

World(Minitest::Assertions)
World(CucumberAssertionAliases)
World(CucumberRackHelpers)

# Minitest requires this for World inclusion
def mu_pp(obj) = obj.inspect
