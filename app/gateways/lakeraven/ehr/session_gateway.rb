# frozen_string_literal: true

require "rpms_rpc/api/session"

module Lakeraven
  module EHR
    # Cold-launch bootstrap: resolves a user DUZ to the user's VIM info
    # (CIAVCXUS VIMINFO). RpmsRpc::Session.bootstrap returns only
    # { vim_info: } (rpms-rpc #522). Wraps RpmsRpc::Session. There is no
    # config root: that was the VueCentric client's own setting (CIAVMRPC
    # GETPAR, rpms-rpc #305), and VIMINFO names no site.
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
