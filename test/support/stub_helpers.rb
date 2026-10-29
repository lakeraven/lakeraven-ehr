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
    sc = klass.singleton_class
    name = method_name.to_sym
    kind, visibility = classify_singleton_entry(sc, name)

    hidden = nil
    prepend_original = nil
    if kind == :owned
      entry = sc.instance_method(name)
      if entry.owner != sc
        prepend_original = own_singleton_instance_method(sc, name)
      else
        hidden = unique_hidden_alias(sc, name)
        sc.send(:alias_method, hidden, name)
      end
    end

    restored = false
    -> do
      return if restored

      restored = true
      clear_singleton_stub(sc, name, kind)

      case kind
      when :owned
        if prepend_original
          sc.send(:define_method, name, prepend_original)
          sc.send(visibility, name)
        else
          sc.send(:alias_method, name, hidden)
          sc.send(:remove_method, hidden)
          sc.send(visibility, name)
        end
      when :visibility_only
        sc.send(visibility, name)
      when :undefined
        sc.send(:undef_method, name) unless sc.undefined_instance_methods.include?(name)
      end
    end
  end

  def classify_singleton_entry(sc, name)
    if sc.undefined_instance_methods.include?(name)
      [ :undefined, nil ]
    elsif singleton_class_own_method?(sc, name)
      visibility = singleton_method_visibility(sc, name)
      if visibility_only_singleton_entry?(sc, name)
        [ :visibility_only, visibility ]
      else
        [ :owned, visibility ]
      end
    else
      [ :absent, nil ]
    end
  end

  def visibility_only_singleton_entry?(sc, name)
    parent_um = sc.superclass.instance_method(name)
    sc.instance_method(name) == parent_um
  rescue NameError
    false
  end

  def clear_singleton_stub(sc, name, kind)
    if singleton_class_own_method?(sc, name)
      sc.send(:remove_method, name)
    elsif sc.undefined_instance_methods.include?(name) && kind != :undefined
      sc.send(:define_method, name) { nil }
      sc.send(:remove_method, name)
    end
  end

  def unique_hidden_alias(sc, name)
    :"__stub_helpers_#{sc.object_id}_#{name}_#{Process.pid}__"
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

  private_class_method :singleton_method_restore, :classify_singleton_entry,
                       :visibility_only_singleton_entry?, :clear_singleton_stub,
                       :unique_hidden_alias,
                       :own_singleton_instance_method, :singleton_method_visibility,
                       :singleton_class_own_method?
end
