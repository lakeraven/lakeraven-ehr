# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"
require File.expand_path("../../test/dummy/config/environment", __dir__)

# test_helper pulls in rails/test_help, which installs Minitest's at_exit
# runner. Under cucumber that runner parsed CUCUMBER's ARGV at exit and died
# on any option it did not know ("invalid option: --tags"), so every run
# that passed a tag, a path or a formatter other than the default ended with
# minitest's usage text and a non-zero exit. Telling Minitest its runner is
# already installed (its own guard) keeps it out of a process that is not a
# minitest process. `rails test` never loads this file.
require "minitest"
Minitest.class_variable_set(:@@installed_at_exit, true)

require File.expand_path("../../test/test_helper", __dir__)
require "minitest/assertions"
require "rack/test"
# Browser specs (features/bprm_twin/**): Capybara over the in-process
# rack_test driver, which submits real forms to the real routes with no
# JavaScript. The stories they prove live in rpms-ux (docs/bprm/README.md).
require "capybara/cucumber"
Capybara.app = Rails.application
Capybara.default_driver = :rack_test

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
