# frozen_string_literal: true

require "rpms_rpc/capabilities"

module Lakeraven
  module EHR
    # Imaging-access predicate fired on every chart open.
    # Wraps RpmsRpc::Capabilities.imaging_user? (lakeraven/rpms-rpc#101).
    #
    # Accepts a plain DUZ string/integer at the engine boundary and adapts
    # to the user-shaped object the underlying predicate expects.
    class CapabilitiesGateway
      UserId = Struct.new(:duz)
      private_constant :UserId

      def self.imaging_user?(duz)
        return false if duz.nil? || duz.to_s.strip.empty?

        RpmsRpc::Capabilities.imaging_user?(UserId.new(duz.to_s))
      end
    end
  end
end
