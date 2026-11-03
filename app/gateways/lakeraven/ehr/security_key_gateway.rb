# frozen_string_literal: true

require "rpms_rpc/api/authentication"

module Lakeraven
  module EHR
    # Which of the named SECURITY KEYs the signed-on user holds, asked with
    # CIAVCXUS HASKEYS through RpmsRpc::Authentication.held_keys (rpms-rpc#318).
    # It is in CIAV VUECENTRIC's RPC multiple, so a least-privilege CIA user can
    # ask it about themself.
    #
    # The gem answers nil when it could not ask (a refusal, no reply, or a reply
    # that does not answer every name). That is not "holds none": the sign-on
    # must not go ahead on keys nobody read (#578), so it raises, and the
    # sign-on is refused as unavailable.
    class SecurityKeyGateway
      class Unreadable < RpmsRpc::Client::RpcError; end

      def self.held(names, via: ::RpmsRpc::Authentication)
        held = via.held_keys(names)
        raise Unreadable, "security keys could not be read (CIAVCXUS HASKEYS)" if held.nil?

        held
      end
    end
  end
end
