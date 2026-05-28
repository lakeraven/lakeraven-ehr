# frozen_string_literal: true

require "rpms_rpc/api/session"

module Lakeraven
  module EHR
    # Cold-launch bootstrap: resolves a user DUZ to client-config root,
    # registry hints, and the user's default division IEN.
    # Wraps RpmsRpc::Session (lakeraven/rpms-rpc#99).
    class SessionGateway
      def self.bootstrap(duz)
        RpmsRpc::Session.bootstrap(duz.to_s)
      end
    end
  end
end
