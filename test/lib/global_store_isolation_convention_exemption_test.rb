# frozen_string_literal: true

require "test_helper"
require_relative "global_store_isolation_convention_test"

# Spec for object-identity EXEMPTED handling in GlobalStoreIsolationConventionTest.
# See issue: alias of an exempted class must not fail the convention check.
class GlobalStoreIsolationConventionExemptionTest < ActiveSupport::TestCase
  EXEMPT_ALIAS = :ExemptAliasProbe
  REGISTERED_ALIAS = :RegisteredResetAliasProbe
  UNREGISTERED_PROBE = :UnregisteredResetProbe
  UNREGISTERED_ALIAS = :UnregisteredResetAliasProbe

  test "alias of exempted class does not fail convention check" do
    Lakeraven::EHR.const_set(EXEMPT_ALIAS, Lakeraven::EHR::BehavioralHealthProgramConfiguration)
    not_called = convention_check_not_called
    assert_empty not_called,
                 "exempted store must not appear in not_called when only reachable via alias " \
                 "(got: #{not_called.join(', ')})"
  ensure
    remove_ehr_const(EXEMPT_ALIAS)
  end

  test "alias of registered resetter passes convention check" do
    Lakeraven::EHR.const_set(REGISTERED_ALIAS, Lakeraven::EHR::LoginThrottle)
    not_called = convention_check_not_called
    assert_empty not_called,
                 "registered resetter must stay covered when referenced via alias " \
                 "(got: #{not_called.join(', ')})"
  ensure
    remove_ehr_const(REGISTERED_ALIAS)
  end

  test "unregistered resetter is reported and alias does not hide it" do
    probe = Class.new
    probe.define_singleton_method(:reset!) {}
    Lakeraven::EHR.const_set(UNREGISTERED_PROBE, probe)
    probe_constant = "Lakeraven::EHR::#{UNREGISTERED_PROBE}"

    not_called = convention_check_not_called
    assert_includes not_called, probe_constant,
                    "unregistered class-level reset! must be listed as not called"

    Lakeraven::EHR.const_set(UNREGISTERED_ALIAS, Lakeraven::EHR.const_get(UNREGISTERED_PROBE))
    not_called_with_alias = convention_check_not_called
    assert_includes not_called_with_alias, probe_constant,
                    "alias of unregistered resetter must not hide it from convention check"
    refute_empty not_called_with_alias
  ensure
    remove_ehr_const(UNREGISTERED_ALIAS)
    remove_ehr_const(UNREGISTERED_PROBE)
  end

  private

  def convention_check_not_called
    probe = GlobalStoreIsolationConventionTest.new("convention_probe")
    probe.send(:eager_load_engine!)
    resetters = probe.send(:constants_with_class_level_reset)
    called = resetters.to_h { |constant_name, _klass, _method| [ constant_name, false ] }
    probe.send(:invoke_with_reset_stubs, resetters, called) { GlobalStoreIsolation.reset! }
    called.reject { |_name, was_called| was_called }.keys.sort
  end

  def remove_ehr_const(name)
    return unless Lakeraven::EHR.const_defined?(name, false)

    Lakeraven::EHR.send(:remove_const, name)
  end
end
