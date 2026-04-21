# frozen_string_literal: true

module Lakeraven
  module EHR
    class AllergyIntolerance
      def self.for_patient(dfn)
        AllergyIntoleranceGateway.for_patient(dfn)
      end
    end
  end
end
