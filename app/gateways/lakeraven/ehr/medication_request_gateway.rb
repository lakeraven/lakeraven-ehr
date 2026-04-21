# frozen_string_literal: true


require "rpms_rpc/mappings"
module Lakeraven
  module EHR
    class MedicationRequestGateway < BaseGateway
      def self.for_patient(dfn)
        RpmsRpc::DataMapper.medication_list.fetch_many(rpc_client, dfn.to_s)
      end
    end
  end
end
