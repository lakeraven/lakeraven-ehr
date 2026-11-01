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
  NO_SUCH_EXEMPT_PROBE = :NoSuchExemptProbe
  NO_RESET_EXEMPT_PROBE = :NoResetExemptProbe
  CANONICAL_EXEMPT_PROBE = :CanonicalExemptProbe
  ALIAS_EXEMPT_PROBE = :AliasExemptProbe

  BEHAVIORAL_HEALTH_EXEMPT_ENTRY = {
    "Lakeraven::EHR::BehavioralHealthProgramConfiguration" =>
      "ActiveRecord-backed, delete_all, rolled back by the per-test transaction"
  }.freeze

  test "alias of exempted class does not fail convention check" do
    Lakeraven::EHR.const_set(EXEMPT_ALIAS, Lakeraven::EHR::BehavioralHealthProgramConfiguration)
    failure = run_convention_check
    assert_nil failure,
               "exempted store must not fail convention check when only reachable via alias " \
               "(got: #{failure})"
  ensure
    remove_ehr_const(EXEMPT_ALIAS)
  end

  test "alias of registered resetter passes convention check" do
    Lakeraven::EHR.const_set(REGISTERED_ALIAS, Lakeraven::EHR::LoginThrottle)
    failure = run_convention_check
    assert_nil failure,
               "registered resetter must stay covered when referenced via alias " \
               "(got: #{failure})"
  ensure
    remove_ehr_const(REGISTERED_ALIAS)
  end

  test "unregistered resetter is reported and alias does not hide it" do
    probe = Class.new
    probe.define_singleton_method(:reset!) { }
    Lakeraven::EHR.const_set(UNREGISTERED_PROBE, probe)
    probe_constant = "Lakeraven::EHR::#{UNREGISTERED_PROBE}"

    failure = run_convention_check
    refute_nil failure, "unregistered class-level reset! must fail convention check"
    assert_includes failure, probe_constant,
                    "unregistered class-level reset! must be named in failure message"

    Lakeraven::EHR.const_set(UNREGISTERED_ALIAS, Lakeraven::EHR.const_get(UNREGISTERED_PROBE))
    failure_with_alias = run_convention_check
    refute_nil failure_with_alias,
               "alias of unregistered resetter must not hide it from convention check"
    assert_includes failure_with_alias, probe_constant,
                    "failure message must still name unregistered resetter when alias exists"
  ensure
    remove_ehr_const(UNREGISTERED_ALIAS)
    remove_ehr_const(UNREGISTERED_PROBE)
  end

  test "EXEMPTED entry that does not resolve fails convention check naming the key" do
    stale_key = "Lakeraven::EHR::#{NO_SUCH_EXEMPT_PROBE}"
    with_exempted_replaced(stale_key => "synthetic stale exemption") do
      failure = run_convention_check
      refute_nil failure, "unresolvable EXEMPTED key must fail convention check"
      assert_includes failure, stale_key,
                      "failure message must name the stale EXEMPTED key"
    end
  end

  test "EXEMPTED entry that resolves but has no class-level reset fails naming the key" do
    no_reset = Class.new
    Lakeraven::EHR.const_set(NO_RESET_EXEMPT_PROBE, no_reset)
    exempt_key = "Lakeraven::EHR::#{NO_RESET_EXEMPT_PROBE}"
    with_exempted_replaced(exempt_key => "synthetic no-op exemption") do
      failure = run_convention_check
      refute_nil failure,
                 "EXEMPTED key with no class-level reset must fail convention check"
      assert_includes failure, exempt_key,
                      "failure message must name the offending EXEMPTED key"
    end
  ensure
    remove_ehr_const(NO_RESET_EXEMPT_PROBE)
  end

  test "EXEMPTED key that is an alias of a resetter fails naming the alias key" do
    canonical = Class.new
    canonical.define_singleton_method(:reset!) { }
    Lakeraven::EHR.const_set(CANONICAL_EXEMPT_PROBE, canonical)
    Lakeraven::EHR.const_set(ALIAS_EXEMPT_PROBE, Lakeraven::EHR.const_get(CANONICAL_EXEMPT_PROBE))
    alias_key = "Lakeraven::EHR::#{ALIAS_EXEMPT_PROBE}"
    with_exempted_replaced(alias_key => "synthetic alias exemption") do
      failure = run_convention_check
      refute_nil failure, "EXEMPTED alias key must fail convention check"
      assert_includes failure, alias_key,
                      "failure message must name the EXEMPTED alias key"
    end
  ensure
    remove_ehr_const(ALIAS_EXEMPT_PROBE)
    remove_ehr_const(CANONICAL_EXEMPT_PROBE)
  end

  test "convention check fails when no class-level resetters are found" do
    failure = run_convention_check do |probe|
      probe.define_singleton_method(:constants_with_class_level_reset) { [] }
    end
    refute_nil failure,
               "empty resetter list must not pass convention check vacuously"
  end

  test "NoMethodError from class_level_reset_method is not reported as stale EXEMPTED entry" do
    synthetic_message = "synthetic introspection failure"
    error = assert_raises(NoMethodError) do
      run_convention_check do |probe|
        probe.define_singleton_method(:class_level_reset_method) do |_klass|
          raise NoMethodError, synthetic_message
        end
      end
    end
    assert_equal synthetic_message, error.message
  end

  private

  def run_convention_check
    name = convention_test_method_name
    probe = GlobalStoreIsolationConventionTest.new(name)
    begin
      yield probe if block_given?
      probe.send(name)
      nil
    rescue Minitest::Assertion => e
      e.message
    end
  end

  def convention_test_method_name
    methods = GlobalStoreIsolationConventionTest.runnable_methods
    assert_equal 1, methods.size,
                 "expected exactly one runnable convention test method"
    methods.first
  end

  def with_exempted_replaced(extra_entries)
    original = GlobalStoreIsolationConventionTest::EXEMPTED
    replacement = BEHAVIORAL_HEALTH_EXEMPT_ENTRY.merge(extra_entries).freeze
    GlobalStoreIsolationConventionTest.send(:remove_const, :EXEMPTED)
    GlobalStoreIsolationConventionTest.const_set(:EXEMPTED, replacement)
    yield
  ensure
    GlobalStoreIsolationConventionTest.send(:remove_const, :EXEMPTED)
    GlobalStoreIsolationConventionTest.const_set(:EXEMPTED, original)
  end

  def remove_ehr_const(name)
    return unless Lakeraven::EHR.const_defined?(name, false)

    Lakeraven::EHR.send(:remove_const, name)
  end
end
