# frozen_string_literal: true

module Lakeraven
  module EHR
    class ServiceRequest
      def self.for_patient(dfn)
        ServiceRequestGateway.for_patient(dfn)
      end
    end
  end
end
