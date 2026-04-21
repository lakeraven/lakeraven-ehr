# frozen_string_literal: true

require "rpms_rpc/mappings"

module Lakeraven
  module EHR
    class ServiceRequestGateway
      def self.for_patient(dfn)
        RpmsRpc::DataMapper.referral_search.fetch_many(dfn.to_s)
      end
    end
  end
end
