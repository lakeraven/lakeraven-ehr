# frozen_string_literal: true

module Lakeraven
  module EHR
    class BaseGateway
      class << self
        def rpc_client
          if Rails.env.test?
            GatewayFactory.gateway
          else
            @rpc_client ||= GatewayFactory.gateway
          end
        end

        def reset_rpc_client!
          @rpc_client = nil
        end

        private

        def empty_response?(response)
          response.nil? || response.empty?
        end
      end
    end
  end
end
