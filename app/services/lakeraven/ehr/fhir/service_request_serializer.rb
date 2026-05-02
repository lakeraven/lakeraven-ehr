# frozen_string_literal: true

module Lakeraven
  module EHR
    module FHIR
      class ServiceRequestSerializer
        def initialize(service_request, policy: nil)
          @sr = service_request
          @policy = policy || RedactionPolicy.new(view: :full)
        end

        def to_h
          resource = @sr.to_fhir
          @policy.apply(resource)
        end
      end
    end
  end
end
