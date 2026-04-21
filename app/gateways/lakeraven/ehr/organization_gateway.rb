# frozen_string_literal: true

require "rpms_rpc/mappings"

module Lakeraven
  module EHR
    class OrganizationGateway
      def self.find(ien)
        RpmsRpc::DataMapper.institution.fetch_one(ien.to_s)
      end
    end
  end
end
