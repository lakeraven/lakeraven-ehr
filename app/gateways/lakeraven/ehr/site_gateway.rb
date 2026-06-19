# frozen_string_literal: true

require "rpms_rpc/api/site"

module Lakeraven
  module EHR
    # Division (site) context: list accessible divisions, look up the
    # currently-selected one, and switch the active division.
    # Wraps RpmsRpc::Site 
    class SiteGateway
      def self.list(duz, via: default_provider)
        return [] if via.nil?

        via.list(duz.to_s)
      end

      def self.current(duz, via: default_provider)
        return nil if via.nil?

        via.current(duz.to_s)
      end

      def self.select(duz, site_ien, via: default_provider)
        return false if via.nil?

        via.select(duz.to_s, site_ien.to_s)
      end

      def self.default_provider
        ::RpmsRpc::Site
      end
    end
  end
end
