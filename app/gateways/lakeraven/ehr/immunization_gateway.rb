# frozen_string_literal: true

require "rpms_rpc/mappings"

module Lakeraven
  module EHR
    class ImmunizationGateway
      def self.for_patient(dfn)
        RpmsRpc::DataMapper.allergy_list.fetch_many(dfn.to_s)
      end
    end
  end
end
