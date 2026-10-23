# frozen_string_literal: true

module Lakeraven
  module EHR
    # One guard for every IHS-only gateway entry point (#647).
    #
    # Prepended onto the gateway's singleton class, so the capability check
    # runs before the method body and before any backend call. Replacing the
    # method later (a stub, a restore) does not move the guard: it stays in
    # front and `super` reaches whatever body is installed underneath.
    #
    # `instance_method` and `method` return the gateway's own method, not
    # this guard, so a caller that saves a method and writes it back does
    # not overwrite the body with the guard.
    module CapabilityGuard
      module_function

      def protect(gateway, capability, *method_names)
        eigen = gateway.singleton_class
        eigen.prepend(guard_for(capability, method_names))
        expose_declared_methods(eigen)
      end

      def ensure!(capability)
        return if BackendRegistry.current.provides?(capability)

        raise FeatureUnavailable.new(capability)
      end

      def guard_for(capability, method_names)
        Module.new do
          method_names.each do |name|
            define_method(name) do |*args, **kwargs, &block|
              CapabilityGuard.ensure!(capability)
              super(*args, **kwargs, &block)
            end
          end
        end
      end

      def expose_declared_methods(eigen)
        return if eigen.instance_variable_get(:@capability_methods_exposed)

        eigen.instance_variable_set(:@capability_methods_exposed, true)
        define_method_lookup(eigen)
      end

      def define_method_lookup(eigen)
        eigen.define_singleton_method(:instance_method) do |name|
          CapabilityGuard.declared_method(super(name), self)
        end
        eigen.define_method(:method) do |name|
          CapabilityGuard.declared_method(super(name), singleton_class)
        end
      end

      def declared_method(found, home)
        cursor = found
        cursor = cursor.super_method while cursor && cursor.owner != home
        cursor || found
      end
    end
  end
end
