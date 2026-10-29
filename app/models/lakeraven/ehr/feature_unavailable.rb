# frozen_string_literal: true

module Lakeraven
  module EHR
    # The current backend does not provide an IHS-only capability (#647).
    # Gateways raise this before any backend call. Controllers render it.
    class FeatureUnavailable < StandardError
      attr_reader :capability

      def initialize(capability)
        @capability = capability
        super("#{capability} is not available on this system")
      end
    end
  end
end
