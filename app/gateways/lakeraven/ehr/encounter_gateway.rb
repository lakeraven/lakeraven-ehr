# frozen_string_literal: true

require "rpms_rpc/api/encounter"

module Lakeraven
  module EHR
    class EncounterGateway
      def self.for_patient(dfn)
        RpmsRpc::Encounter.for_patient(dfn.to_s)
      end
    end
  end
end
