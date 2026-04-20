# frozen_string_literal: true

# Factory for selecting gateway adapters.
#
# Decision hierarchy (Approach C: Rails.env gates, env var refines):
#
#   1. Rails.env determines the safety boundary:
#      - production  → always RPC, RPMS_INTEGRATION_MODE ignored
#      - test        → always mock, unless RPC_TEST_MODE overrides
#      - development → defaults to RPC, RPMS_INTEGRATION_MODE can select mock
#
#   2. RPMS_INTEGRATION_MODE refines within development:
#      - rpc / rpms_rpc / vista_rpc  → RPC adapter
#      - mock                        → Mock adapter (dev only)
#      - nil                         → RPC (default)
#      - anything else               → ConfigurationError
#
#   3. ALLOW_RPC_FALLBACK_TO_MOCK opts into graceful degradation
#      when RPC is unavailable (development only).
module Lakeraven
  module EHR
    class GatewayFactory
      class ConfigurationError < StandardError; end

      VALID_RPC_MODES = %w[rpms_rpc rpc vista_rpc].freeze
      VALID_MODES = (VALID_RPC_MODES + %w[mock]).freeze

      def self.gateway
        return test_gateway if Rails.env.test?
        return production_gateway if Rails.env.production?

        development_gateway
      end

      # True when using live RPC (not mock mode).
      def self.rpc_mode?
        return false if Rails.env.test?
        return true if Rails.env.production?
        ENV["RPMS_INTEGRATION_MODE"] != "mock"
      end

      # True when RPC mode is active (always true outside test/mock).
      def self.strict_mode?
        rpc_mode?
      end

      VALID_PROTOCOLS = %w[cia xwb bmx].freeze

      # --- Private environment-specific gateways ---

      # Production: RPC client directly (no adapter wrapper).
      private_class_method def self.production_gateway
        validate_mode_if_set!
        rpc_client_instance
      end

      # Development: RPC client by default, mock if explicitly requested.
      private_class_method def self.development_gateway
        mode = ENV["RPMS_INTEGRATION_MODE"]

        case mode
        when *VALID_RPC_MODES, nil
          rpc_client_instance
        when "mock"
          mock_gateway_adapter
        else
          raise ConfigurationError,
            "Unknown RPMS_INTEGRATION_MODE: '#{mode}'. " \
            "Valid values: #{VALID_MODES.join(', ')}"
        end
      end

      # Test: mock by default, RPC client if RPC_TEST_MODE overrides.
      private_class_method def self.test_gateway
        case ENV.fetch("RPC_TEST_MODE", "mock")
        when "protocol", "real"
          rpc_client_instance
        else
          mock_gateway_adapter
        end
      end

      # Return the appropriate RPC client based on RPC_PROTOCOL env var.
      # Defaults to CIA/XWB (port 9100). Set RPC_PROTOCOL=bmx for BMX (port 9200).
      private_class_method def self.rpc_client_instance
        case ENV.fetch("RPC_PROTOCOL", "cia").downcase
        when "bmx"
          RpmsRpc::BmxClient.instance
        when "cia", "xwb"
          RpmsRpc::CiaClient.instance
        else
          raise ConfigurationError,
            "Unknown RPC_PROTOCOL: '#{ENV['RPC_PROTOCOL']}'. " \
            "Valid values: #{VALID_PROTOCOLS.join(', ')}"
        end
      end

      # Validate env var if someone sets it in production (catch typos).
      private_class_method def self.validate_mode_if_set!
        mode = ENV["RPMS_INTEGRATION_MODE"]
        return if mode.nil? || VALID_RPC_MODES.include?(mode)

        if mode == "mock"
          raise ConfigurationError,
            "RPMS_INTEGRATION_MODE=mock is not allowed in production."
        end

        raise ConfigurationError,
          "Unknown RPMS_INTEGRATION_MODE: '#{mode}'. " \
          "Valid values: #{VALID_RPC_MODES.join(', ')}"
      end

      private_class_method def self.mock_gateway_adapter
        require_relative "../../../../test/support/mock_gateway_adapter"
        MockGatewayAdapter.instance
      end
    end
  end
end
