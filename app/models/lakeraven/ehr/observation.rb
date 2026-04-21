# frozen_string_literal: true

module Lakeraven
  module EHR
    class Observation
      def self.for_patient(dfn)
        ObservationGateway.for_patient(dfn)
      end
    end
  end
end
