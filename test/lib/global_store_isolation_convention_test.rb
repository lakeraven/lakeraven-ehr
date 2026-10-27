# frozen_string_literal: true

require "test_helper"

# Every process-global in-memory store with a class-level reset hook must be
# cleared via GlobalStoreIsolation::STORE_RESETS (see test/support/global_store_isolation.rb).
class GlobalStoreIsolationConventionTest < ActiveSupport::TestCase
  RESET_METHOD_NAMES = %i[reset! reset_instance! reset_store!].freeze

  # Classes that define reset! / reset_instance! / reset_store! but are not
  # suite-wide process globals — each entry must stay commented with a reason.
  EXEMPTED = {
    "Lakeraven::EHR::BehavioralHealthProgramConfiguration" =>
      "ActiveRecord-backed, delete_all, rolled back by the per-test transaction"
  }.freeze

  GENERIC_RESET_METHOD_OWNERS = [
    Object,
    Kernel,
    BasicObject
  ].freeze

  test "every class-level store reset is invoked by GlobalStoreIsolation.reset!" do
    eager_load_engine!

    resetters = constants_with_class_level_reset
    called = resetters.to_h { |constant_name, _klass, _method| [ constant_name, false ] }

    invoke_with_reset_stubs(resetters, called) { GlobalStoreIsolation.reset! }

    not_called = called.reject { |_name, was_called| was_called }.keys.sort
    assert_empty not_called,
                 "GlobalStoreIsolation.reset! must call each store resetter (register missing " \
                 "classes in GlobalStoreIsolation::STORE_RESETS or EXEMPTED with a reason): " \
                 "#{not_called.join(', ')}"
  end

  private

  def eager_load_engine!
    Lakeraven::EHR::Engine.eager_load!
  end

  def constants_with_class_level_reset
    walk_constants(Lakeraven::EHR).sort_by(&:first)
  end

  def walk_constants(mod, prefix = "Lakeraven::EHR", visited = nil)
    visited ||= {}
    return [] if visited[mod.object_id]

    visited[mod.object_id] = true

    found_self =
      if EXEMPTED.key?(prefix)
        nil
      else
        class_level_reset_method(mod)&.then { |method_name| [ prefix, mod, method_name ] }
      end

    nested = mod.constants(false).flat_map do |name|
      const = mod.const_get(name)
      next [] unless const.is_a?(Module)

      full_name = "#{prefix}::#{name}"
      found =
        if EXEMPTED.key?(full_name)
          nil
        else
          class_level_reset_method(const)&.then { |method_name| [ full_name, const, method_name ] }
        end

      child_nested = walk_constants(const, full_name, visited)
      found ? [ found ] + child_nested : child_nested
    end

    found_self ? [ found_self ] + nested : nested
  end

  def class_level_reset_method(klass)
    RESET_METHOD_NAMES.each do |method_name|
      next unless klass.respond_to?(method_name, true)

      method = klass.method(method_name)
      next unless reset_method_owned_by_constant?(klass, method)

      return method_name
    end
    nil
  end

  def reset_method_owned_by_constant?(klass, method)
    owner = method.owner
    return false if generic_reset_method_owner?(owner)

    owner == klass.singleton_class || klass.singleton_class.ancestors.include?(owner)
  end

  def generic_reset_method_owner?(owner)
    return true unless owner.is_a?(Module)
    return true if GENERIC_RESET_METHOD_OWNERS.include?(owner)

    name = owner.name
    return true if name&.start_with?("ActiveRecord::", "ActionView::", "ActionController::", "ActiveSupport::")

    false
  end

  def invoke_with_reset_stubs(resetters, called)
    if resetters.empty?
      yield
    else
      constant_name, klass, method_name = resetters.first
      with_recording_singleton_stub(klass, method_name, -> { called[constant_name] = true }) do
        invoke_with_reset_stubs(resetters.drop(1), called) { yield }
      end
    end
  end

  def with_recording_singleton_stub(klass, method_name, on_call)
    restore = StubHelpers.send(:singleton_method_restore, klass, method_name)
    klass.define_singleton_method(method_name) { on_call.call }
    yield
  ensure
    restore&.call
  end
end
