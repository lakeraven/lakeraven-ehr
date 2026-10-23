# frozen_string_literal: true

require "rpms_rpc/api/medication"

module Lakeraven
  module EHR
    class MedicationRequestGateway
      # The active medication list carries each order's RPMS status, which
      # the condensed list does not (#628).
      def self.for_patient(dfn)
        RpmsRpc::Medication.active_for_patient(dfn.to_s)
      end
    end
  end
end
