# frozen_string_literal: true

require "rpms_rpc/api/session"

module Lakeraven
  module EHR
    # Cold-launch bootstrap: resolves a user DUZ to client-config root,
    # registry hints, and the user's default division IEN.
    # Wraps RpmsRpc::Session
    class SessionGateway
      def self.bootstrap(duz, via: default_provider)
        return nil if via.nil?

        via.bootstrap(duz.to_s)
      end

      def self.default_provider
        ::RpmsRpc::Session
      end
    end
  end
end
