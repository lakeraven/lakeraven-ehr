# frozen_string_literal: true

module Lakeraven
  module EHR
    # Imaging-access predicate fired on every chart open.
    #
    # No provider ships with the engine. At the pinned gem version
    # imaging_user? still exists over MAGGUSERKEYS, an RPC no built 9.0
    # image registers (rpms-rpc#207); upstream removed it. The engine no
    # longer uses it, and the default fails closed: default_provider is
    # nil, so imaging_user? with no via: returns false and sends no RPC.
    # A caller can still inject a provider through via:.
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
        nil
      end
    end
  end
end
