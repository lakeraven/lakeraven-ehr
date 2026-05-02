# frozen_string_literal: true

require "rpms_rpc/api/procedure"

module Lakeraven
  module EHR
    class ProcedureGateway
      def self.for_patient(dfn)
        RpmsRpc::Procedure.for_patient(dfn.to_s)
      end
    end
  end
end
