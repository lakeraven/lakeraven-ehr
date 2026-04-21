# frozen_string_literal: true


require "rpms_rpc/mappings"
module Lakeraven
  module EHR
    class ObservationGateway < BaseGateway
      def self.for_patient(dfn)
        RpmsRpc::DataMapper.vitals.fetch_many(rpc_client, dfn.to_s)
      end
    end
  end
end
