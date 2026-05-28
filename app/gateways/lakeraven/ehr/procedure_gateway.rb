# frozen_string_literal: true

require "rpms_rpc/api/procedure"

module Lakeraven
  module EHR
    class ProcedureGateway
      def self.for_patient(dfn)
        RpmsRpc::Procedure.for_patient(dfn.to_s)
      end

      # Record a CPT procedure against an open encounter.
      def self.add(dfn, visit_ien, cpt_code, modifiers: [], narrative: nil, quantity: 1)
        RpmsRpc::Procedure.add(dfn.to_s, visit_ien.to_s, cpt_code,
          modifiers: modifiers, narrative: narrative, quantity: quantity)
      end
    end
  end
end
