# frozen_string_literal: true

# BaseGateway - Common functionality for all RPC gateways
#
# Provides shared methods for RPC communication, response parsing,
# and error handling.

module Lakeraven
  module EHR
    class BaseGateway
      class RpcError < StandardError; end

      class << self
        # RPC client accessor (public for testing)
        # In test: routes through GatewayFactory → MockGatewayAdapter (has call_rpc)
        # In prod/dev: routes through GatewayFactory to protocol-specific client
        def rpc_client
          if Rails.env.test?
            GatewayFactory.gateway
          else
            @rpc_client ||= GatewayFactory.gateway
          end
        end

        # Reset cached RPC client (for test isolation or mode switching)
        def reset_rpc_client!
          @rpc_client = nil
        end

        private

        # Check if RPC response is empty
        def empty_response?(response)
          response.nil? || response.empty?
        end

        # Parse caret-delimited field
        def parse_field(field, type = :string)
          return nil if field.nil? || field.empty?

          case type
          when :integer
            field.to_i
          when :boolean
            field == "1" || field.casecmp("yes").zero?
          when :date
            RpmsRpc::FilemanDateParser.parse_date(field)
          when :datetime
            RpmsRpc::FilemanDateParser.parse_datetime(field)
          else
            field
          end
        end

        # Parse caret-delimited response line
        # @param line [String] Response line with ^-delimited fields
        # @return [Array<String>]
        def parse_line(line)
          return [] if line.nil? || line.empty?
          line.sub(/^~`/, "").split("^")
        end

        # Safe parse with error logging
        # @yield Block to execute with error handling
        # @return [Object, nil] Result of block or nil on error
        def safe_parse
          yield
        rescue => e
          sanitized_msg = sanitize_error(e.message)
          Rails.logger.error("#{self.name} parse error: #{sanitized_msg}")
          nil
        end

        # Sanitize error message to remove PHI before logging or returning
        def sanitize_error(message)
          RpmsRpc::PhiSanitizer.sanitize_message(message.to_s)
        end

        # Log a warning with sanitized message
        def log_sanitized_warning(method, exception)
          sanitized_msg = sanitize_error(exception.message)
          Rails.logger.warn("#{self.name}.#{method} failed: #{sanitized_msg}")
        end

        # Log an error with sanitized message
        def log_sanitized_error(method, exception)
          sanitized_msg = sanitize_error(exception.message)
          Rails.logger.error("#{self.name}.#{method} failed: #{sanitized_msg}")
        end
      end
    end
  end
end
