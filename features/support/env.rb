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

World(Minitest::Assertions)
World(CucumberRackHelpers)

# Minitest requires this for World inclusion
def mu_pp(obj) = obj.inspect
