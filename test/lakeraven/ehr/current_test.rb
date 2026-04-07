# frozen_string_literal: true

require "test_helper"

class Lakeraven::EHR::CurrentTest < ActiveSupport::TestCase
  setup do
    Lakeraven::EHR::Current.reset!
  end

  teardown do
    Lakeraven::EHR::Current.reset!
  end

  test "tenant_identifier defaults to nil" do
    assert_nil Lakeraven::EHR::Current.tenant_identifier
  end

  test "facility_identifier defaults to nil" do
    assert_nil Lakeraven::EHR::Current.facility_identifier
  end

  test "tenant_identifier can be set and read" do
    Lakeraven::EHR::Current.tenant_identifier = "tnt_test"
    assert_equal "tnt_test", Lakeraven::EHR::Current.tenant_identifier
  end

  test "facility_identifier can be set and read" do
    Lakeraven::EHR::Current.facility_identifier = "fac_main"
    assert_equal "fac_main", Lakeraven::EHR::Current.facility_identifier
  end

  test "reset! clears both tenant and facility" do
    Lakeraven::EHR::Current.tenant_identifier = "tnt_test"
    Lakeraven::EHR::Current.facility_identifier = "fac_main"
    Lakeraven::EHR::Current.reset!
    assert_nil Lakeraven::EHR::Current.tenant_identifier
    assert_nil Lakeraven::EHR::Current.facility_identifier
  end

  test "with_tenant block sets and restores tenant_identifier" do
    Lakeraven::EHR::Current.tenant_identifier = "tnt_outer"
    Lakeraven::EHR::Current.with_tenant("tnt_inner") do
      assert_equal "tnt_inner", Lakeraven::EHR::Current.tenant_identifier
    end
    assert_equal "tnt_outer", Lakeraven::EHR::Current.tenant_identifier
  end

  test "with_tenant restores tenant even if block raises" do
    Lakeraven::EHR::Current.tenant_identifier = "tnt_outer"
    assert_raises(RuntimeError) do
      Lakeraven::EHR::Current.with_tenant("tnt_inner") do
        raise "boom"
      end
    end
    assert_equal "tnt_outer", Lakeraven::EHR::Current.tenant_identifier
  end

  test "MissingTenantContextError exists and inherits from StandardError" do
    assert Lakeraven::EHR::MissingTenantContextError < StandardError
  end

  # Regression for Copilot review #1 on PR #1: Current.reset! must not
  # clear sibling ActiveSupport::CurrentAttributes subclasses, because
  # this engine is meant to be embedded in host apps that have their
  # own Current state. Using clear_all (the previous implementation)
  # would wipe the host's state every time the engine reset between
  # scenarios — a hostile thing for an engine to do.
  #
  # CurrentAttributes uses .name in its internal lookup key, so the
  # stand-in host class must be a named constant rather than an
  # anonymous Class.new — anonymous subclasses raise NoMethodError on
  # name.to_sym before they can be exercised.
  class FakeHostCurrent < ActiveSupport::CurrentAttributes
    attribute :host_value
  end

  test "reset! does not clear sibling CurrentAttributes subclasses" do
    FakeHostCurrent.host_value = "host-state-survives"

    Lakeraven::EHR::Current.tenant_identifier = "tnt_test"
    Lakeraven::EHR::Current.reset!

    assert_nil Lakeraven::EHR::Current.tenant_identifier,
      "engine Current should be cleared by reset!"
    assert_equal "host-state-survives", FakeHostCurrent.host_value,
      "host app's Current state should survive engine reset"
  ensure
    FakeHostCurrent.host_value = nil
  end
end
