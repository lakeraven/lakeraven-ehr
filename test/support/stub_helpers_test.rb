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
  INHERITED_PROTECTED = :sh673_inherited_protected
  NEVER_DEFINED = :sh673_never_defined
  PREPENDED_PUBLIC = :sh673_prepended_public
  PREPENDED_PRIVATE = :sh673_prepended_private
  UNDEF_HIDDEN = :sh673_undef_hidden
  EXTENDED_PUBLIC = :sh673_extended_public
  EXTENDED_PRIVATE = :sh673_extended_private
  PARENT_PREPENDED_ONLY = :sh673_parent_prepended_only
  INTERMEDIATE_METHOD = :sh673_p4
  VISIBILITY_ONLY_LOOKUP = :sh673_lookup
  GRANDPARENT_INHERITED_PRIVATE = :sh673_gp_inherited_private
  ALIAS_FOO = :sh673_foo
  ALIAS_BAR = :sh673_bar

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

  # --- Restore idempotency (lakeraven-ehr#673 round-1) ---

  test "restore proc called twice is a no-op for an inherited public singleton method" do
    parent, child = host_with_inherited_singleton_methods

    restore = install_singleton_stub(child, INHERITED_PUBLIC, STUB_VALUE)
    restore.call
    restore.call

    assert_equal :sh673_parent_public, child.send(INHERITED_PUBLIC)
    assert_inherited_singleton_visible(child, INHERITED_PUBLIC, :public, parent)
  end

  test "restore proc called twice is a no-op for an inherited private singleton method" do
    parent, child = host_with_inherited_singleton_methods

    restore = install_singleton_stub(child, INHERITED_PRIVATE, STUB_VALUE)
    restore.call
    restore.call

    assert_equal :sh673_parent_private, child.send(INHERITED_PRIVATE)
    assert_inherited_singleton_visible(child, INHERITED_PRIVATE, :private, parent)
  end

  test "restore proc called twice is a no-op for an inherited protected singleton method" do
    parent, child = host_with_inherited_singleton_methods

    restore = install_singleton_stub(child, INHERITED_PROTECTED, STUB_VALUE)
    restore.call
    restore.call

    assert_equal :sh673_parent_protected, child.send(INHERITED_PROTECTED)
    assert_inherited_singleton_visible(child, INHERITED_PROTECTED, :protected, parent)
  end

  test "restore proc called twice on an owned singleton method leaves the original intact" do
    host = host_with_owned_singleton_method(:public, OWNED_PUBLIC, ORIGINAL)

    restore = install_singleton_stub(host, OWNED_PUBLIC, STUB_VALUE)
    restore.call
    restore.call

    assert_after_restore(host, OWNED_PUBLIC, ORIGINAL, :public)
  end

  test "Cucumber After-hook style reverse_each over restore procs restores every stub including another receiver" do
    host_a = host_with_owned_singleton_method(:public, OWNED_PUBLIC, ORIGINAL)
    host_b = Class.new

    restore_a = install_singleton_stub(host_a, OWNED_PUBLIC, STUB_VALUE)
    restore_b = install_singleton_stub(host_b, NEVER_DEFINED, STUB_VALUE)

    [ restore_a, restore_b, restore_b ].reverse_each(&:call)

    assert_after_restore(host_a, OWNED_PUBLIC, ORIGINAL, :public)
    refute host_b.singleton_class.method_defined?(NEVER_DEFINED)
    refute host_b.singleton_class.private_method_defined?(NEVER_DEFINED)
  end

  test "with_stub returns normally when the block removes the stub on an inherited singleton method" do
    _parent, child = host_with_inherited_singleton_methods

    result = with_stub(child, INHERITED_PUBLIC, STUB_VALUE) do
      child.singleton_class.send(:remove_method, INHERITED_PUBLIC)
      :sh673_block_result
    end

    assert_equal :sh673_block_result, result
    assert_equal :sh673_parent_public, child.send(INHERITED_PUBLIC)
  end

  # --- Prepended module on the singleton class (lakeraven-ehr#673 round-1) ---

  test "with_stub restores an owned public singleton method with a prepended module and super chain" do
    host = host_with_prepended_owned_singleton_method(:public, PREPENDED_PUBLIC, :sh673_own)

    with_stub(host, PREPENDED_PUBLIC, STUB_VALUE) { }

    assert_equal [ :sh673_pre, :sh673_own ], host.send(PREPENDED_PUBLIC)
    assert_includes host.singleton_class.instance_methods(false), PREPENDED_PUBLIC
  end

  test "with_stub restores an owned private singleton method with a prepended module and super chain" do
    host = host_with_prepended_owned_singleton_method(:private, PREPENDED_PRIVATE, :sh673_own_private)

    with_stub(host, PREPENDED_PRIVATE, STUB_VALUE) { }

    assert_equal [ :sh673_pre, :sh673_own_private ], host.send(PREPENDED_PRIVATE)
  end

  # --- undef_method hides inherited singleton method (lakeraven-ehr#673 round-1) ---

  test "with_stub after undef_method on the receiver singleton class leaves the method hidden" do
    parent = Class.new
    parent.define_singleton_method(UNDEF_HIDDEN) { :sh673_parent_hidden }

    child = Class.new(parent)
    child.singleton_class.send(:undef_method, UNDEF_HIDDEN)
    refute child.respond_to?(UNDEF_HIDDEN)

    with_stub(child, UNDEF_HIDDEN, STUB_VALUE) { }

    assert_undef_hidden_on_receiver(child, UNDEF_HIDDEN)
  end

  # --- undef on receiver stays hidden after stub (lakeraven-ehr#673 round-2) ---

  test "with_stub after undef on receiver leaves extended public singleton method hidden" do
    host = host_with_extended_singleton_method(:public, EXTENDED_PUBLIC, :sh673_ext_public)
    host.singleton_class.send(:undef_method, EXTENDED_PUBLIC)
    assert_undef_hidden_on_receiver(host, EXTENDED_PUBLIC)

    with_stub(host, EXTENDED_PUBLIC, STUB_VALUE) { }

    assert_undef_hidden_on_receiver(host, EXTENDED_PUBLIC)
  end

  test "with_stub after undef on receiver leaves extended private singleton method hidden" do
    host = host_with_extended_singleton_method(:private, EXTENDED_PRIVATE, :sh673_ext_private)
    host.singleton_class.send(:undef_method, EXTENDED_PRIVATE)
    assert_undef_hidden_on_receiver(host, EXTENDED_PRIVATE, include_all: true)

    with_stub(host, EXTENDED_PRIVATE, STUB_VALUE) { }

    assert_undef_hidden_on_receiver(host, EXTENDED_PRIVATE, include_all: true)
  end

  test "install_singleton_stub restore after undef on receiver leaves Module name hidden on the class" do
    host = Class.new
    host.singleton_class.send(:undef_method, :name)
    assert_undef_hidden_on_receiver(host, :name)

    restore = install_singleton_stub(host, :name, STUB_VALUE)
    restore.call

    assert_undef_hidden_on_receiver(host, :name)
  end

  test "with_stub after undef on receiver leaves Class new hidden" do
    host = Class.new
    host.singleton_class.send(:undef_method, :new)
    assert_undef_hidden_on_receiver(host, :new)

    with_stub(host, :new, STUB_VALUE) { }

    assert_undef_hidden_on_receiver(host, :new)
  end

  test "with_stub after undef on receiver leaves Kernel frozen? hidden on a plain Object" do
    host = Object.new
    host.singleton_class.send(:undef_method, :frozen?)
    assert_undef_hidden_on_receiver(host, :frozen?)

    with_stub(host, :frozen?, STUB_VALUE) { }

    assert_undef_hidden_on_receiver(host, :frozen?)
  end

  test "with_stub after undef on receiver leaves method from prepended parent singleton module hidden" do
    host = host_with_undef_parent_prepended_singleton_only(PARENT_PREPENDED_ONLY)
    assert_undef_hidden_on_receiver(host, PARENT_PREPENDED_ONLY)

    with_stub(host, PARENT_PREPENDED_ONLY, STUB_VALUE) { }

    assert_undef_hidden_on_receiver(host, PARENT_PREPENDED_ONLY)
  end

  test "with_stub restores undef on receiver when the block removes the stub method" do
    host = host_with_undef_inherited_on_receiver(UNDEF_HIDDEN)

    result = with_stub(host, UNDEF_HIDDEN, STUB_VALUE) do
      host.singleton_class.send(:remove_method, UNDEF_HIDDEN)
      :sh673_block_result
    end

    assert_equal :sh673_block_result, result
    assert_undef_hidden_on_receiver(host, UNDEF_HIDDEN)
  end

  test "with_stub on leaf does not leave undef on leaf when undef lived on intermediate ancestor singleton" do
    _grandparent, mid, leaf = host_with_intermediate_singleton_undef(INTERMEDIATE_METHOD)

    with_stub(leaf, INTERMEDIATE_METHOD, STUB_VALUE) { }

    assert_no_own_or_undef_entry(leaf, INTERMEDIATE_METHOD)

    mid.define_singleton_method(INTERMEDIATE_METHOD) { :sh673_mid_restored }
    assert_equal :sh673_mid_restored, leaf.send(INTERMEDIATE_METHOD)
  end

  # --- Visibility-only entry on child singleton (lakeraven-ehr#673 round-3) ---

  test "with_stub on child with visibility-only private inherited singleton keeps private and follows parent" do
    parent, child = host_with_visibility_only_inherited_singleton(:private, VISIBILITY_ONLY_LOOKUP, :sh673_real)

    with_stub(child, VISIBILITY_ONLY_LOOKUP, STUB_VALUE) { }

    assert_singleton_visibility(singleton_of(child), VISIBILITY_ONLY_LOOKUP, :private)
    assert_equal :sh673_real, child.send(VISIBILITY_ONLY_LOOKUP)
    assert_equal parent.singleton_class.instance_method(VISIBILITY_ONLY_LOOKUP),
                 singleton_of(child).instance_method(VISIBILITY_ONLY_LOOKUP)

    with_stub(parent, VISIBILITY_ONLY_LOOKUP, :sh673_parent_stub) do
      assert_equal :sh673_parent_stub, child.send(VISIBILITY_ONLY_LOOKUP)
    end

    parent.define_singleton_method(VISIBILITY_ONLY_LOOKUP) { :sh673_redefined }
    assert_equal :sh673_redefined, child.send(VISIBILITY_ONLY_LOOKUP)
  end

  test "with_stub on child with visibility-only protected inherited singleton keeps protected and follows parent" do
    parent, child = host_with_visibility_only_inherited_singleton(:protected, VISIBILITY_ONLY_LOOKUP, :sh673_real)

    with_stub(child, VISIBILITY_ONLY_LOOKUP, STUB_VALUE) { }

    assert_singleton_visibility(singleton_of(child), VISIBILITY_ONLY_LOOKUP, :protected)
    assert_equal :sh673_real, child.send(VISIBILITY_ONLY_LOOKUP)
    assert_equal parent.singleton_class.instance_method(VISIBILITY_ONLY_LOOKUP),
                 singleton_of(child).instance_method(VISIBILITY_ONLY_LOOKUP)

    with_stub(parent, VISIBILITY_ONLY_LOOKUP, :sh673_parent_stub) do
      assert_equal :sh673_parent_stub, child.send(VISIBILITY_ONLY_LOOKUP)
    end

    parent.define_singleton_method(VISIBILITY_ONLY_LOOKUP) { :sh673_redefined }
    assert_equal :sh673_redefined, child.send(VISIBILITY_ONLY_LOOKUP)
  end

  test "with_stub on child with visibility-only private new still allocates via Class new without an owned copy" do
    child = Class.new(Class.new)
    child.private_class_method :new

    with_stub(child, :new, STUB_VALUE) { }

    assert_singleton_visibility(singleton_of(child), :new, :private)
    assert_raises(NoMethodError) { child.new }
    instance = child.send(:new)
    assert_instance_of child, instance
    assert_equal child.singleton_class.superclass.instance_method(:new),
                 child.singleton_class.instance_method(:new)
  end

  test "with_stub on child leaves grandparent private singleton body with no own entry on child" do
    grandparent = Class.new
    grandparent.singleton_class.class_eval do
      define_method(GRANDPARENT_INHERITED_PRIVATE) { :sh673_gp_body }
      private GRANDPARENT_INHERITED_PRIVATE
    end
    mid = Class.new(grandparent)
    child = Class.new(mid)

    with_stub(child, GRANDPARENT_INHERITED_PRIVATE, STUB_VALUE) { }

    assert_singleton_visibility(singleton_of(child), GRANDPARENT_INHERITED_PRIVATE, :private)
    assert_equal :sh673_gp_body, child.send(GRANDPARENT_INHERITED_PRIVATE)
    assert_equal grandparent.singleton_class.instance_method(GRANDPARENT_INHERITED_PRIVATE),
                 singleton_of(child).instance_method(GRANDPARENT_INHERITED_PRIVATE)
    assert_no_own_or_undef_entry(child, GRANDPARENT_INHERITED_PRIVATE)
  end

  # --- Alias of ancestor singleton method with super (lakeraven-ehr#673 round-3) ---

  test "with_stub on public alias of ancestor singleton method restores alias without double super" do
    child = host_with_aliased_ancestor_singleton_method(:public)
    expected = [ :sh673_parent, :sh673_base ]

    assert_equal expected, child.send(ALIAS_BAR)

    with_stub(child, ALIAS_BAR, STUB_VALUE) { }

    assert_equal expected, child.send(ALIAS_BAR)
  end

  test "with_stub on private alias of ancestor singleton method restores alias without double super" do
    child = host_with_aliased_ancestor_singleton_method(:private)
    expected = [ :sh673_parent, :sh673_base ]

    assert_equal expected, child.send(ALIAS_BAR)

    with_stub(child, ALIAS_BAR, STUB_VALUE) { }

    assert_equal expected, child.send(ALIAS_BAR)
  end

  # --- Block undefs stub on inherited or never-defined method (lakeraven-ehr#673 round-3) ---

  test "with_stub when block undefs inherited stub leaves no undef entry and shows inherited method" do
    parent, child = host_with_inherited_singleton_methods

    with_stub(child, INHERITED_PUBLIC, STUB_VALUE) do
      child.singleton_class.send(:undef_method, INHERITED_PUBLIC)
    end

    refute singleton_undef_entry?(child, INHERITED_PUBLIC)
    assert_equal :sh673_parent_public, child.send(INHERITED_PUBLIC)
    assert_inherited_singleton_visible(child, INHERITED_PUBLIC, :public, parent)
  end

  test "with_stub when block undefs never-defined stub leaves method absent without undef entry" do
    host = Class.new
    refute host.singleton_class.method_defined?(NEVER_DEFINED)

    with_stub(host, NEVER_DEFINED, STUB_VALUE) do
      host.singleton_class.send(:undef_method, NEVER_DEFINED)
    end

    refute singleton_undef_entry?(host, NEVER_DEFINED)
    refute host.singleton_class.method_defined?(NEVER_DEFINED)
    refute host.singleton_class.private_method_defined?(NEVER_DEFINED)
    assert_raises(NoMethodError) { host.send(NEVER_DEFINED) }
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
      define_method(INHERITED_PROTECTED) { :sh673_parent_protected }
      protected INHERITED_PROTECTED
    end
    child = Class.new(parent)
    [ parent, child ]
  end

  def host_with_prepended_owned_singleton_method(visibility, method_name, own_return)
    host = Class.new
    host.singleton_class.class_eval do
      define_method(method_name) { |*_args, **_kwargs| own_return }
      send(visibility, method_name)
    end
    prepend = Module.new do
      define_method(method_name) do |*_args, **_kwargs, &block|
        [ :sh673_pre, super(*_args, **_kwargs, &block) ]
      end
    end
    host.singleton_class.prepend(prepend)
    host
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

  def host_with_extended_singleton_method(visibility, method_name, return_value)
    host = Class.new
    extension = Module.new do
      define_method(method_name) { |*_args, **_kwargs| return_value }
      send(visibility, method_name) if visibility != :public
    end
    host.extend(extension)
    host
  end

  def host_with_undef_inherited_on_receiver(method_name)
    parent = Class.new
    parent.define_singleton_method(method_name) { :sh673_parent_hidden }

    child = Class.new(parent)
    child.singleton_class.send(:undef_method, method_name)
    child
  end

  def host_with_undef_parent_prepended_singleton_only(method_name)
    parent = Class.new
    prepend = Module.new do
      define_method(method_name) { :sh673_from_parent_prepend }
    end
    parent.singleton_class.prepend(prepend)
    child = Class.new(parent)
    child.singleton_class.send(:undef_method, method_name)
    child
  end

  def host_with_intermediate_singleton_undef(method_name)
    grandparent = Class.new
    grandparent.define_singleton_method(method_name) { :sh673_grandparent }

    mid = Class.new(grandparent)
    mid.singleton_class.send(:undef_method, method_name)

    leaf = Class.new(mid)
    [ grandparent, mid, leaf ]
  end

  def host_with_visibility_only_inherited_singleton(visibility, method_name, return_value)
    parent = Class.new
    parent.define_singleton_method(method_name) { return_value }
    child = Class.new(parent)
    child.singleton_class.class_eval do
      send(visibility, method_name)
    end
    [ parent, child ]
  end

  def host_with_aliased_ancestor_singleton_method(bar_visibility)
    base = Class.new
    base.define_singleton_method(ALIAS_FOO) { :sh673_base }
    parent = Class.new(base)
    parent.define_singleton_method(ALIAS_FOO) { [ :sh673_parent, super() ] }
    child = Class.new(parent)
    child.singleton_class.class_eval do
      alias_method ALIAS_BAR, ALIAS_FOO
      send(bar_visibility, ALIAS_BAR) unless bar_visibility == :public
    end
    child
  end

  def assert_undef_hidden_on_receiver(host, method_name, include_all: false)
    refute host.respond_to?(method_name, include_all),
           "expected #{method_name} to stay hidden from respond_to?"
    assert_raises(NoMethodError) { host.send(method_name) }
    assert singleton_undef_entry?(host, method_name),
           "expected receiver singleton class to retain an undef entry for #{method_name}"
  end

  def assert_no_own_or_undef_entry(host, method_name)
    singleton = singleton_of(host)
    name = method_name.to_sym
    refute singleton.instance_methods(false).include?(name)
    refute singleton.private_instance_methods(false).include?(name)
    refute singleton.protected_instance_methods(false).include?(name)
    refute singleton_undef_entry?(host, name),
           "receiver singleton class should not retain an undef entry for #{name}"
  end

  def singleton_undef_entry?(host, method_name)
    singleton_of(host).undefined_instance_methods.include?(method_name.to_sym)
  end
end
