# frozen_string_literal: true

require "test_helper"

# lakeraven-ehr#682: capacity-refusal audit must survive interleaved refusals and must not
# retain raw credential strings in RateLimit's process-wide refusal slot.
class RateLimitRefusalReasonTest < ActiveSupport::TestCase
  include RateLimitTestHelper

  SECRET_IDENTITY = "bearer:SECRET-TOKEN-682"

  teardown do
    Lakeraven::EHR::RateLimit.reset! if Lakeraven::EHR.const_defined?(:RateLimit, false) &&
      Lakeraven::EHR::RateLimit.respond_to?(:reset!)
  end

  test "first capacity refusal is auditable at most once per window when nothing overwrites the slot" do
    mod = rate_limit_module!
    newcomer_ip = build_fail_closed_saturated_table!(mod)

    refute mod.permit?(identity: "bearer:newcomer", ip: newcomer_ip),
           "new identity must be refused when storage is full (#682 capacity audit)"
    assert mod.audit_due?(identity: "bearer:newcomer", ip: newcomer_ip),
           "capacity refusal must be auditable the first time (#682 capacity audit)"
    refute mod.audit_due?(identity: "bearer:newcomer", ip: newcomer_ip),
           "capacity audit must fire at most once per window (#682 capacity audit)"
  ensure
    mod.reset! if mod.respond_to?(:reset!)
  end

  test "capacity refusal stays auditable after another thread records a non-capacity refusal" do
    mod = rate_limit_module!
    newcomer_ip = build_fail_closed_saturated_table!(mod)
    capacity_identity = "bearer:capacity-audit-victim"
    sync = Mutex.new
    cv = ConditionVariable.new
    phase = :start

    interleaver = Thread.new do
      sync.synchronize do
        cv.wait(sync) until phase == :capacity_refused
      end
      refute mod.permit?(identity: "bearer:full-1", ip: "198.51.100.1"),
             "saturated identity must refuse for rate, not capacity (#682 Finding A setup)"
      sync.synchronize do
        phase = :rate_refused
        cv.broadcast
      end
    end

    sync.synchronize do
      refute mod.permit?(identity: capacity_identity, ip: newcomer_ip),
             "newcomer must be refused for capacity (#682 Finding A)"
      phase = :capacity_refused
      cv.broadcast
      cv.wait(sync) until phase == :rate_refused
    end
    interleaver.join

    assert mod.audit_due?(identity: capacity_identity, ip: newcomer_ip),
           "capacity refusal must stay auditable after an interleaved rate refusal (#682 Finding A)"
  ensure
    mod.reset! if mod.respond_to?(:reset!)
  end

  test "capacity refusal does not leave the raw bearer token in RateLimit storage" do
    mod = rate_limit_module!
    newcomer_ip = build_fail_closed_saturated_table!(mod)
    needle = "SECRET-TOKEN-682"

    refute mod.permit?(identity: SECRET_IDENTITY, ip: newcomer_ip),
           "probe identity must be refused for capacity (#682 Finding B setup)"

    assert_no_rate_limit_secret_leak!(mod, needle,
                                      "RateLimit must not retain raw credential material after capacity refusal (#682 Finding B)")
  ensure
    mod.reset! if mod.respond_to?(:reset!)
  end

  private

  def assert_no_rate_limit_secret_leak!(mod, needle, message)
    roots = rate_limit_walk_roots(mod)
    leaked = rate_limit_values_containing(roots, needle)
    assert leaked.empty?, "#{message}; found #{needle.inspect} in #{leaked.inspect}"
  end

  def rate_limit_walk_roots(mod)
    roots = []
    [ mod, mod.singleton_class ].each do |receiver|
      receiver.instance_variables.each do |name|
        roots << [ receiver, name, receiver.instance_variable_get(name) ]
      end
    end
    mod.class_variables.each do |name|
      roots << [ mod, name, mod.class_variable_get(name) ]
    end
    mod.constants(false).each do |name|
      roots << [ mod, name, mod.const_get(name) ]
    end
    roots
  end

  def rate_limit_values_containing(roots, needle)
    hits = []
    seen = {}
    queue = roots.map { |(_owner, label, value)| [ label, value ] }

    until queue.empty?
      label, value = queue.shift
      next if value.nil?

      if value.is_a?(String) && value.include?(needle)
        hits << label
        next
      end

      oid = value.object_id
      next if seen[oid]

      seen[oid] = true

      case value
      when Hash
        value.each do |key, entry|
          queue << [ "#{label}[:#{key}]", entry ]
          queue << [ "#{label}.key(#{key.inspect})", key ] if key.is_a?(String) && key.include?(needle)
        end
      when Array
        value.each_with_index do |entry, index|
          queue << [ "#{label}[#{index}]", entry ]
        end
      end
    end

    hits
  end
end
