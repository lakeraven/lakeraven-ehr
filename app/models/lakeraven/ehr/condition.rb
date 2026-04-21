# frozen_string_literal: true

module Lakeraven
  module EHR
    class Condition
      def self.for_patient(dfn)
        ConditionGateway.for_patient(dfn)
      end
    end
  end
end
