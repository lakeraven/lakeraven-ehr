# frozen_string_literal: true

require "rpms_rpc/api/order"

module Lakeraven
  module EHR
    # Clinical-order list APIs — a patient's unsigned orders, or a patient's
    # orders under one view and display group.
    # Wraps RpmsRpc::Order
    class OrderGateway
      # UNSIGN^ORWOR (ORWOR UNSIGN) takes the PATIENT and answers for the
      # signed-on user (ORWOR.m:114), so there is no user argument.
      def self.unsigned_for_patient(dfn, via: default_provider)
        return [] if via.nil?

        via.unsigned_for_patient(dfn.to_s)
      end

      # filter is a RpmsRpc::Order::FILTER_IDS view (:active, :all, :unsigned
      # ...); display_group a file 100.98 IEN (AGET's default, 1).
      def self.list(dfn, filter: :active, display_group: ::RpmsRpc::Order::DEFAULT_DISPLAY_GROUP, via: default_provider)
        return [] if via.nil?

        via.list(dfn.to_s, filter: filter, display_group: display_group)
      end

      def self.default_provider
        ::RpmsRpc::Order
      end
    end
  end
end
