# frozen_string_literal: true

require "rpms_rpc/api/location"

module Lakeraven
  module EHR
    class LocationGateway
      def self.find(ien)
        RpmsRpc::Location.find(ien)
      end

      def self.search(name)
        Array(RpmsRpc::Location.search(name))
      end
    end
  end
end
