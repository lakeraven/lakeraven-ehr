# frozen_string_literal: true

# Save and restore one singleton method. The previous method is put back in
# ensure, including when the block raises, with its original visibility.
# A method the receiver did not define itself is removed again so an inherited
# method stays inherited.
module StubHelpers
  module_function

  def with_stub(klass, method_name, value)
    restore = install_singleton_stub(klass, method_name, value)
    yield
  ensure
    restore&.call
  end

  # Returns the restore proc with_stub runs in ensure. Cucumber stores the
  # same proc and calls it from an After hook (stub_gateway).
  def install_singleton_stub(klass, method_name, value)
    restore = singleton_method_restore(klass, method_name)
    klass.define_singleton_method(method_name) { |*_args, **_kwargs| value }
    restore
  end

  def singleton_method_restore(klass, method_name)
    singleton = klass.singleton_class
    if owned_singleton_method?(singleton, method_name)
      original = singleton.instance_method(method_name)
      visibility = singleton_method_visibility(singleton, method_name)
      -> do
        singleton.send(:define_method, method_name, original)
        singleton.send(visibility, method_name)
      end
    else
      -> { remove_singleton_method(singleton, method_name) }
    end
  end

  def owned_singleton_method?(singleton, method_name)
    singleton_method_defined?(singleton, method_name) &&
      singleton.instance_method(method_name).owner == singleton
  end

  def singleton_method_defined?(singleton, method_name)
    singleton.method_defined?(method_name) ||
      singleton.private_method_defined?(method_name) ||
      singleton.protected_method_defined?(method_name)
  end

  def singleton_method_visibility(singleton, method_name)
    if singleton.public_method_defined?(method_name)
      :public
    elsif singleton.private_method_defined?(method_name)
      :private
    else
      :protected
    end
  end

  def remove_singleton_method(singleton, method_name)
    return unless singleton_method_defined?(singleton, method_name)

    singleton.send(:remove_method, method_name)
  end
  private_class_method :singleton_method_restore, :owned_singleton_method?,
                       :singleton_method_defined?, :singleton_method_visibility,
                       :remove_singleton_method
end
