# frozen_string_literal: true

# GatewayAccess - Shared gateway access pattern for RPC-based models
#
# Provides consistent access to GatewayFactory.gateway across all models,
# eliminating duplicated calls and enabling easier testing/mocking.
module Lakeraven
  module EHR
    module GatewayAccess
      extend ActiveSupport::Concern

      class_methods do
        # Class-level gateway access for finder methods
        def gateway
          Lakeraven::EHR::GatewayFactory.gateway
        end
      end

      # Instance-level gateway access for CRUD operations
      def gateway
        @gateway ||= self.class.gateway
      end
    end
  end
end
