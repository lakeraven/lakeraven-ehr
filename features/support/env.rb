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

  # Clear engine-managed state so rows don't bleed across scenarios.
  # Audit rows are read-only via ActiveRecord but delete_all hits the
  # SQL layer directly and is allowed.
  Lakeraven::EHR::AuditEvent.delete_all
  Lakeraven::EHR::LaunchContext.delete_all

  # Stub the SMART resource owner authenticator so OAuth scenarios
  # that touch /oauth/authorize don't trip the default
  # NotConfiguredError. Real host applications override this with
  # a real user lookup.
  Lakeraven::EHR.configuration.resource_owner_authenticator =
    ->(_controller) { Struct.new(:id).new(1) }
end
