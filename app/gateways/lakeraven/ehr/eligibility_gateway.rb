# frozen_string_literal: true

require "rpms_rpc/mappings"

module Lakeraven
  module EHR
    class EligibilityGateway
      def self.patient_eligibility(dfn)
        RpmsRpc::DataMapper.vfc_eligibility.fetch_one(dfn.to_s) || { code: nil, label: nil }
      end

      def self.list_codes
        RpmsRpc::DataMapper.vfc_eligibility_list.fetch_many
      end
    end
  end
end
