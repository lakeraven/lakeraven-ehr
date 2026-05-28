# frozen_string_literal: true

require "rpms_rpc/api/site"

module Lakeraven
  module EHR
    # Division (site) context: list accessible divisions, look up the
    # currently-selected one, and switch the active division.
    # Wraps RpmsRpc::Site (lakeraven/rpms-rpc#100).
    class SiteGateway
      def self.list(duz)
        RpmsRpc::Site.list(duz.to_s)
      end

      def self.current(duz)
        RpmsRpc::Site.current(duz.to_s)
      end

      def self.select(duz, site_ien)
        RpmsRpc::Site.select(duz.to_s, site_ien.to_s)
      end
    end
  end
end
