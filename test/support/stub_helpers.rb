# frozen_string_literal: true

# Save and restore one singleton method. The previous method is put back in
# ensure, including when the block raises, with its original visibility.
# A method the receiver did not define itself is removed again so an inherited
# method stays inherited. An undef entry on the receiver singleton class is
# restored after the stub is removed.
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
    name = method_name.to_sym
    if owned_singleton_method?(singleton, name)
      original = own_singleton_instance_method(singleton, name)
      visibility = singleton_method_visibility(singleton, name)
      -> do
        singleton.send(:define_method, name, original)
        singleton.send(visibility, name)
      end
    elsif singleton.undefined_instance_methods.include?(name)
      -> { restore_undefined_singleton_method(singleton, name) }
    else
      -> { restore_absent_singleton_method(singleton, name) }
    end
  end

  def owned_singleton_method?(singleton, method_name)
    singleton_class_own_method?(singleton, method_name)
  end

  def own_singleton_instance_method(singleton, method_name)
    name = method_name.to_sym
    method = singleton.instance_method(name)
    method = method.super_method while method && method.owner != singleton
    method
  end

  def singleton_method_visibility(singleton, method_name)
    name = method_name.to_sym
    if singleton.private_instance_methods(false).include?(name)
      :private
    elsif singleton.protected_instance_methods(false).include?(name)
      :protected
    else
      :public
    end
  end

  def singleton_class_own_method?(singleton, method_name)
    name = method_name.to_sym
    singleton.instance_methods(false).include?(name) ||
      singleton.private_instance_methods(false).include?(name) ||
      singleton.protected_instance_methods(false).include?(name)
  end

  def restore_undefined_singleton_method(singleton, method_name)
    name = method_name.to_sym
    singleton.send(:remove_method, name) if owned_singleton_method?(singleton, name)
    singleton.send(:undef_method, name) unless singleton.undefined_instance_methods.include?(name)
  end

  def restore_absent_singleton_method(singleton, method_name)
    name = method_name.to_sym
    return unless owned_singleton_method?(singleton, name)

    singleton.send(:remove_method, name)
  end

  private_class_method :singleton_method_restore, :owned_singleton_method?,
                       :own_singleton_instance_method, :singleton_method_visibility,
                       :singleton_class_own_method?, :restore_undefined_singleton_method,
                       :restore_absent_singleton_method
end
