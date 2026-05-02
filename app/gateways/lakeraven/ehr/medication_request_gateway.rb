# frozen_string_literal: true

require "rpms_rpc/api/medication"

module Lakeraven
  module EHR
    class MedicationRequestGateway
      def self.for_patient(dfn)
        RpmsRpc::Medication.for_patient(dfn.to_s)
      end
    end
  end
end
