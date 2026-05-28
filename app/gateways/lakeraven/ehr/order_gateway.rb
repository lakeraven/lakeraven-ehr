# frozen_string_literal: true

begin
  require "rpms_rpc/api/order"
rescue LoadError
  # rpms-rpc gem does not yet expose RpmsRpc::Order.
end

module Lakeraven
  module EHR
    # Clinical-order list APIs — a user's unsigned queue, or a patient's
    # chart filtered by status and view.
    # Wraps RpmsRpc::Order (lakeraven/rpms-rpc#68).
    class OrderGateway
      def self.unsigned_for_user(user_duz, via: default_provider)
        return [] if via.nil?

        via.unsigned_for_user(user_duz.to_s)
      end

      def self.list(dfn, status: :all, view: :default, via: default_provider)
        return [] if via.nil?

        via.list(dfn.to_s, status: status, view: view)
      end

      def self.default_provider
        return nil unless defined?(::RpmsRpc::Order) &&
                          ::RpmsRpc::Order.respond_to?(:list)
        ::RpmsRpc::Order
      end
    end
  end
end
