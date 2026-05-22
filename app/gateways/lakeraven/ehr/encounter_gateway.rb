# frozen_string_literal: true

require "rpms_rpc/api/encounter"

module Lakeraven
  module EHR
    class EncounterGateway
      def self.for_patient(dfn)
        RpmsRpc::Encounter.for_patient(dfn.to_s)
      end

      # Open an active encounter — returns a hydrated context hash or nil if not found.
      # Delegates to RpmsRpc::Encounter.open (added in rpms-rpc#55).
      # Normalizes identifiers to strings to match the convention used by
      # `for_patient` and the rest of the gateway layer.
      def self.open(dfn, visit_ien)
        RpmsRpc::Encounter.open(dfn.to_s, visit_ien.to_s)
      end
    end
  end
end
