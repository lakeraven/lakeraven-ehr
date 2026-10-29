# frozen_string_literal: true

require "test_helper"

# Regression spec for StubHelpers ownership and visibility (lakeraven-ehr#673).
# Throwaway classes only; synthetic method names only.
class SharedStubHelpersTest < ActiveSupport::TestCase
  OWNED_PUBLIC = :sh673_owned_public
  OWNED_PRIVATE = :sh673_owned_private
  OWNED_PROTECTED = :sh673_owned_protected
  INHERITED_PUBLIC = :sh673_inherited_public
  INHERITED_PRIVATE = :sh673_inherited_private
  NEVER_DEFINED = :sh673_never_defined

  ORIGINAL = :sh673_original
  STUB_VALUE = :sh673_stubbed

  # --- with_stub: owned singleton methods by visibility ---

  test "with_stub on an owned public singleton method stubs, then restores value, ownership, and visibility" do
    host = host_with_owned_singleton_method(:public, OWNED_PUBLIC, ORIGINAL)

    with_stub(host, OWNED_PUBLIC, STUB_VALUE) do
      assert_during_stub(host, OWNED_PUBLIC, STUB_VALUE, :public)
    end

    assert_after_restore(host, OWNED_PUBLIC, ORIGINAL, :public)
  end

  test "with_stub on an owned private singleton method stubs, then restores value, ownership, and visibility" do
    host = host_with_owned_singleton_method(:private, OWNED_PRIVATE, ORIGINAL)

    with_stub(host, OWNED_PRIVATE, STUB_VALUE) do
      assert_during_stub(host, OWNED_PRIVATE, STUB_VALUE, :private)
    end

    assert_after_restore(host, OWNED_PRIVATE, ORIGINAL, :private)
  end

  test "with_stub on an owned protected singleton method stubs, then restores value, ownership, and visibility" do
    host = host_with_owned_singleton_method(:protected, OWNED_PROTECTED, ORIGINAL)

    with_stub(host, OWNED_PROTECTED, STUB_VALUE) do
      assert_during_stub(host, OWNED_PROTECTED, STUB_VALUE, :protected)
    end

    assert_after_restore(host, OWNED_PROTECTED, ORIGINAL, :protected)
  end

  test "with_stub restores an owned private singleton method when the block raises" do
    host = host_with_owned_singleton_method(:private, OWNED_PRIVATE, ORIGINAL)

    assert_raises(RuntimeError) do
      with_stub(host, OWNED_PRIVATE, STUB_VALUE) do
        assert_equal STUB_VALUE, host.send(OWNED_PRIVATE)
        raise "sh673 boom"
      end
    end

    assert_after_restore(host, OWNED_PRIVATE, ORIGINAL, :private)
  end

  test "with_stub restores an owned protected singleton method when the block raises" do
    host = host_with_owned_singleton_method(:protected, OWNED_PROTECTED, ORIGINAL)

    assert_raises(RuntimeError) do
      with_stub(host, OWNED_PROTECTED, STUB_VALUE) do
        assert_equal STUB_VALUE, host.send(OWNED_PROTECTED)
        raise "sh673 boom"
      end
    end

    assert_after_restore(host, OWNED_PROTECTED, ORIGINAL, :protected)
  end

  # --- install_singleton_stub + restore proc (Cucumber After-hook path) ---

  test "install_singleton_stub on an owned public singleton method stubs, then restore proc restores value, ownership, and visibility" do
    host = host_with_owned_singleton_method(:public, OWNED_PUBLIC, ORIGINAL)

    restore = install_singleton_stub(host, OWNED_PUBLIC, STUB_VALUE)
    assert_during_stub(host, OWNED_PUBLIC, STUB_VALUE, :public)
    restore.call

    assert_after_restore(host, OWNED_PUBLIC, ORIGINAL, :public)
  end

  test "install_singleton_stub on an owned private singleton method stubs, then restore proc restores value, ownership, and visibility" do
    host = host_with_owned_singleton_method(:private, OWNED_PRIVATE, ORIGINAL)

    restore = install_singleton_stub(host, OWNED_PRIVATE, STUB_VALUE)
    assert_during_stub(host, OWNED_PRIVATE, STUB_VALUE, :private)
    restore.call

    assert_after_restore(host, OWNED_PRIVATE, ORIGINAL, :private)
  end

  test "install_singleton_stub on an owned protected singleton method stubs, then restore proc restores value, ownership, and visibility" do
    host = host_with_owned_singleton_method(:protected, OWNED_PROTECTED, ORIGINAL)

    restore = install_singleton_stub(host, OWNED_PROTECTED, STUB_VALUE)
    assert_during_stub(host, OWNED_PROTECTED, STUB_VALUE, :protected)
    restore.call

    assert_after_restore(host, OWNED_PROTECTED, ORIGINAL, :protected)
  end

  # --- Not owned: inherited from superclass singleton ---

  test "with_stub on an inherited public singleton method removes the stub and leaves the inherited method with original visibility" do
    parent, child = host_with_inherited_singleton_methods

    with_stub(child, INHERITED_PUBLIC, STUB_VALUE) do
      assert_equal STUB_VALUE, child.send(INHERITED_PUBLIC)
    end

    assert_equal :sh673_parent_public, child.send(INHERITED_PUBLIC)
    assert_inherited_singleton_visible(child, INHERITED_PUBLIC, :public, parent)
  end

  test "with_stub on an inherited private singleton method removes the stub and leaves the inherited method with original visibility" do
    parent, child = host_with_inherited_singleton_methods

    with_stub(child, INHERITED_PRIVATE, STUB_VALUE) do
      assert_equal STUB_VALUE, child.send(INHERITED_PRIVATE)
    end

    assert_equal :sh673_parent_private, child.send(INHERITED_PRIVATE)
    assert_inherited_singleton_visible(child, INHERITED_PRIVATE, :private, parent)
  end

  test "install_singleton_stub restore on an inherited public singleton method removes the stub and leaves the inherited method" do
    parent, child = host_with_inherited_singleton_methods

    restore = install_singleton_stub(child, INHERITED_PUBLIC, STUB_VALUE)
    assert_equal STUB_VALUE, child.send(INHERITED_PUBLIC)
    restore.call

    assert_equal :sh673_parent_public, child.send(INHERITED_PUBLIC)
    assert_inherited_singleton_visible(child, INHERITED_PUBLIC, :public, parent)
  end

  test "install_singleton_stub restore on an inherited private singleton method removes the stub and leaves the inherited method" do
    parent, child = host_with_inherited_singleton_methods

    restore = install_singleton_stub(child, INHERITED_PRIVATE, STUB_VALUE)
    assert_equal STUB_VALUE, child.send(INHERITED_PRIVATE)
    restore.call

    assert_equal :sh673_parent_private, child.send(INHERITED_PRIVATE)
    assert_inherited_singleton_visible(child, INHERITED_PRIVATE, :private, parent)
  end

  # --- Never defined on the receiver ---

  test "with_stub on a never-defined singleton method removes the stub afterward" do
    host = Class.new
    refute host.singleton_class.method_defined?(NEVER_DEFINED)
    refute host.singleton_class.private_method_defined?(NEVER_DEFINED)

    with_stub(host, NEVER_DEFINED, STUB_VALUE) do
      assert_equal STUB_VALUE, host.send(NEVER_DEFINED)
    end

    refute host.singleton_class.method_defined?(NEVER_DEFINED)
    refute host.singleton_class.private_method_defined?(NEVER_DEFINED)
  end

  test "install_singleton_stub restore on a never-defined singleton method removes the stub afterward" do
    host = Class.new

    restore = install_singleton_stub(host, NEVER_DEFINED, STUB_VALUE)
    assert_equal STUB_VALUE, host.send(NEVER_DEFINED)
    restore.call

    refute host.singleton_class.method_defined?(NEVER_DEFINED)
    refute host.singleton_class.private_method_defined?(NEVER_DEFINED)
  end

  private

  def host_with_owned_singleton_method(visibility, method_name, return_value)
    klass = Class.new
    klass.singleton_class.class_eval do
      define_method(method_name) { |*_args, **_kwargs| return_value }
      send(visibility, method_name)
    end
    klass
  end

  def host_with_inherited_singleton_methods
    parent = Class.new
    parent.define_singleton_method(INHERITED_PUBLIC) { :sh673_parent_public }
    parent.singleton_class.class_eval do
      define_method(INHERITED_PRIVATE) { :sh673_parent_private }
      private INHERITED_PRIVATE
    end
    child = Class.new(parent)
    [ parent, child ]
  end

  def singleton_of(host)
    host.singleton_class
  end

  def assert_during_stub(host, method_name, stub_value, _visibility)
    assert_equal stub_value, host.send(method_name),
                 "send should return the stub value while the stub is installed"
    assert singleton_of(host).method_defined?(method_name),
           "stub should be visible to method_defined? while installed"
  end

  def assert_after_restore(host, method_name, original_value, visibility)
    singleton = singleton_of(host)

    assert_equal original_value, host.send(method_name),
                 "send should invoke the restored original implementation"
    assert_equal singleton, singleton.instance_method(method_name).owner,
                 "restored method should still be owned by the receiver singleton class"

    assert_singleton_visibility(singleton, method_name, visibility)

    case visibility
    when :public
      assert_respond_to host, method_name
    when :private
      assert_raises(NoMethodError) { host.public_send(method_name) }
    when :protected
      assert_raises(NoMethodError) { host.public_send(method_name) }
    end
  end

  def assert_singleton_visibility(singleton, method_name, visibility)
    case visibility
    when :public
      assert singleton.public_method_defined?(method_name),
             "expected #{method_name} to be public on the singleton class"
      refute singleton.private_method_defined?(method_name)
      refute singleton.protected_method_defined?(method_name)
    when :private
      assert singleton.private_method_defined?(method_name),
             "expected #{method_name} to be private on the singleton class"
      refute singleton.public_method_defined?(method_name)
      refute singleton.protected_method_defined?(method_name)
    when :protected
      assert singleton.protected_method_defined?(method_name),
             "expected #{method_name} to be protected on the singleton class"
      refute singleton.public_method_defined?(method_name)
      refute singleton.private_method_defined?(method_name)
    end
  end

  def assert_inherited_singleton_visible(child, method_name, visibility, parent)
    singleton = singleton_of(child)
    assert_equal parent.singleton_class, singleton.instance_method(method_name).owner,
                 "receiver singleton class should not own an inherited singleton method"
    assert_singleton_visibility(parent.singleton_class, method_name, visibility)
  end
end
