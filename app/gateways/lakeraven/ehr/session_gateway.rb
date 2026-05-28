# frozen_string_literal: true

begin
  require "rpms_rpc/api/session"
rescue LoadError
  # rpms-rpc gem does not yet expose RpmsRpc::Session.
end

module Lakeraven
  module EHR
    # Cold-launch bootstrap: resolves a user DUZ to client-config root,
    # registry hints, and the user's default division IEN.
    # Wraps RpmsRpc::Session (lakeraven/rpms-rpc#99).
    class SessionGateway
      def self.bootstrap(duz, via: default_provider)
        return nil if via.nil?

        via.bootstrap(duz.to_s)
      end

      def self.default_provider
        return nil unless defined?(::RpmsRpc::Session) &&
                          ::RpmsRpc::Session.respond_to?(:bootstrap)
        ::RpmsRpc::Session
      end
    end
  end
end
