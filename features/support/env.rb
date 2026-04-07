# frozen_string_literal: true

# Cucumber bootstraps from the dummy app so the engine and its
# dependencies are loaded the same way they would be in a host
# application. We don't need a browser, so no Capybara.

ENV["RAILS_ENV"] ||= "test"

require_relative "../../test/dummy/config/environment"
require "lakeraven/ehr"
require "minitest"
require "minitest/assertions"

# Bring Minitest assertions into the Cucumber World so step
# definitions can use assert / assert_equal / refute directly.
World(Minitest::Assertions)

# Reset engine state between scenarios so one scenario can't
# leak adapter or tenant context into the next.
Before do
  Lakeraven::EHR.reset_configuration!
  Lakeraven::EHR::Current.reset!
end
