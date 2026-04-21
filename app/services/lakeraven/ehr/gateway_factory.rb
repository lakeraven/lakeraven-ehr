# frozen_string_literal: true

# Factory for selecting gateway adapters.
#
# Rails.env gates the safety boundary:
#   - production  → always RPC
#   - test        → always mock (unless RPC_TEST_MODE overrides)
#   - development → RPC by default, RPMS_INTEGRATION_MODE=mock for mock
module Lakeraven
  module EHR
    class GatewayFactory
      class ConfigurationError < StandardError; end

      VALID_RPC_MODES = %w[rpms_rpc rpc vista_rpc].freeze
      VALID_MODES = (VALID_RPC_MODES + %w[mock]).freeze
      VALID_PROTOCOLS = %w[cia xwb bmx].freeze

      def self.gateway
        return test_gateway if Rails.env.test?
        return production_gateway if Rails.env.production?

        development_gateway
      end

      def self.rpc_mode?
        return false if Rails.env.test?
        return true if Rails.env.production?

        ENV["RPMS_INTEGRATION_MODE"] != "mock"
      end

      private_class_method def self.production_gateway
        rpc_client_instance
      end

      private_class_method def self.development_gateway
        mode = ENV["RPMS_INTEGRATION_MODE"]
        case mode
        when *VALID_RPC_MODES, nil then rpc_client_instance
        when "mock" then mock_gateway_adapter
        else
          raise ConfigurationError, "Unknown RPMS_INTEGRATION_MODE: '#{mode}'. Valid: #{VALID_MODES.join(', ')}"
        end
      end

      private_class_method def self.test_gateway
        case ENV.fetch("RPC_TEST_MODE", "mock")
        when "protocol", "real" then rpc_client_instance
        else mock_gateway_adapter
        end
      end

      private_class_method def self.rpc_client_instance
        case ENV.fetch("RPC_PROTOCOL", "cia").downcase
        when "bmx" then RpmsRpc::BmxClient.instance
        when "cia", "xwb" then RpmsRpc::CiaClient.instance
        else
          raise ConfigurationError,
                "Unknown RPC_PROTOCOL: '#{ENV['RPC_PROTOCOL']}'. Valid: #{VALID_PROTOCOLS.join(', ')}"
        end
      end

      private_class_method def self.mock_gateway_adapter
        require_relative "../../../../test/support/mock_gateway_adapter"
        MockGatewayAdapter.instance
      end
    end
  end
end
