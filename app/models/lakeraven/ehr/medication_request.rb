# frozen_string_literal: true

module Lakeraven
  module EHR
    class MedicationRequest
      def self.for_patient(dfn)
        MedicationRequestGateway.for_patient(dfn)
      end
    end
  end
end
