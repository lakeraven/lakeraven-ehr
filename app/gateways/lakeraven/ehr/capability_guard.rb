# frozen_string_literal: true

module Lakeraven
  module EHR
    # The shared check for an IHS-only gateway entry point (#647).
    #
    # Each gated method calls ensure! as the first line of its body, so
    # method() and instance_method hit the same check as a normal call.
    module CapabilityGuard
      module_function

      def ensure!(capability)
        return if BackendRegistry.current.provides?(capability)

        raise FeatureUnavailable.new(capability)
      end
    end
  end
end
