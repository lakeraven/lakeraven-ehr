# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"
require File.expand_path("../../test/dummy/config/environment", __dir__)
require File.expand_path("../../test/test_helper", __dir__)
require "minitest/assertions"
require "rack/test"

# test_helper pulls in rails/test_help, which installs Minitest.autorun's
# at_exit runner. Under cucumber that runner re-parses cucumber's ARGV
# (feature paths, -t tags) as minitest options and exits non-zero even
# when every scenario passed. Cucumber is the runner here — neutralize
# the minitest pass so the process exit code is cucumber's own.
def Minitest.run(*) = true

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
