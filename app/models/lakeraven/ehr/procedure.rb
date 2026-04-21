# frozen_string_literal: true

module Lakeraven
  module EHR
    class Procedure
      def self.for_patient(dfn)
        ProcedureGateway.for_patient(dfn)
      end
    end
  end
end
