# frozen_string_literal: true

require "test_helper"

# Regression test for the Zeitwerk EHR-vs-Ehr inflection trap.
#
# When the engine module was renamed from Lakeraven::Ehr (the
# generator default) to Lakeraven::EHR, several scaffold files
# under app/{controllers,models,jobs,helpers}/lakeraven/ehr/ kept
# the old casing. They worked fine in development because Zeitwerk
# resolves files lazily — nothing tried to load them. They worked
# fine in `rake test` because the test runner doesn't eager-load
# unless you ask it to. They blew up the moment anything triggered
# eager loading (production boot, `rails app:zeitwerk:check`,
# Cucumber via the dummy app in some configurations) with a
# Zeitwerk::NameError pointing at the wrong constant.
#
# This test forces eager loading from the unit suite so the trap
# never reopens silently. If a future scaffold file lands with
# `module Ehr` instead of `module EHR`, this test fails before
# the next CI run.
class Lakeraven::EHR::EagerLoadTest < ActiveSupport::TestCase
  test "the engine eager-loads cleanly" do
    assert_nothing_raised do
      Rails.application.eager_load!
    end
  end

  test "scaffold constants resolve to Lakeraven::EHR namespace" do
    assert defined?(Lakeraven::EHR::ApplicationController)
    assert defined?(Lakeraven::EHR::ApplicationRecord)
    assert defined?(Lakeraven::EHR::ApplicationJob)
    assert defined?(Lakeraven::EHR::ApplicationHelper)
  end

  test "no constant is defined under the Lakeraven::Ehr namespace" do
    refute defined?(Lakeraven::Ehr),
      "Lakeraven::Ehr should not exist — the engine namespace is Lakeraven::EHR"
  end
end
