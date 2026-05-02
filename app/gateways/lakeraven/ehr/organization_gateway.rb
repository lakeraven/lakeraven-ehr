# frozen_string_literal: true

require "rpms_rpc/api/organization"

module Lakeraven
  module EHR
    class OrganizationGateway
      def self.find(ien)
        RpmsRpc::Organization.find(ien)
      end
    end
  end
end
