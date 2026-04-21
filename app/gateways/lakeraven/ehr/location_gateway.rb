# frozen_string_literal: true

require "rpms_rpc/mappings"

module Lakeraven
  module EHR
    class LocationGateway
      def self.find(ien)
        RpmsRpc::DataMapper.hospital_location.fetch_one(ien.to_s)
      end
    end
  end
end
