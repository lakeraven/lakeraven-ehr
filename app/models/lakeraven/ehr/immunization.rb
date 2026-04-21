# frozen_string_literal: true

module Lakeraven
  module EHR
    class Immunization
      def self.for_patient(dfn)
        ImmunizationGateway.for_patient(dfn)
      end
    end
  end
end
