# frozen_string_literal: true

begin
  require "rpms_rpc/capabilities"
rescue LoadError
  # rpms-rpc gem does not yet expose RpmsRpc::Capabilities.imaging_user?.
end

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

      def self.imaging_user?(duz, via: default_provider)
        return false if via.nil?
        return false if duz.nil? || duz.to_s.strip.empty?

        via.imaging_user?(UserId.new(duz.to_s))
      end

      def self.default_provider
        return nil unless defined?(::RpmsRpc::Capabilities) &&
                          ::RpmsRpc::Capabilities.respond_to?(:imaging_user?)
        ::RpmsRpc::Capabilities
      end
    end
  end
end
