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

# test_helper (required above for Minitest::Assertions) also installs
# Minitest's at_exit autorun. Under cucumber there are no Minitest suites to
# run, and Minitest's option parser rejects cucumber CLI flags (--tags,
# --publish-quiet), turning a green cucumber run into exit status 1 — which
# would make any CI gate on cucumber meaningless. Neutralize the autorun.
def Minitest.run(_args = [])
  true
end
