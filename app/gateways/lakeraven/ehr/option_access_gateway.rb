# frozen_string_literal: true

require "rpms_rpc/api/authentication"

module Lakeraven
  module EHR
    # Which of the named options the signed-on user may run, asked with ORWU HAS
    # OPTION ACCESS through RpmsRpc::Authentication.option_access (rpms-rpc#490):
    # RPMS's own answer, from the user's primary and secondary menus, locks and
    # out-of-order state.
    #
    # The gem answers nil when it could not ask. That is not "may run none": a
    # session must not be built on options nobody read (#578), so it raises, and
    # the sign-on is refused as unavailable, as SecurityKeyGateway does for keys.
    class OptionAccessGateway
      class Unreadable < RpmsRpc::Client::RpcError; end

      def self.held(names, via: ::RpmsRpc::Authentication)
        held = via.option_access(names)
        raise Unreadable, "option access could not be read (ORWU HAS OPTION ACCESS)" if held.nil?

        held
      end
    end
  end
end
