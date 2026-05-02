# frozen_string_literal: true

module Lakeraven
  module EHR
    module FHIR
      class CommunicationSerializer
        def initialize(communication, policy: nil)
          @comm = communication
          @policy = policy || RedactionPolicy.new(view: :full)
        end

        def to_h
          resource = @comm.to_fhir
          @policy.apply(resource)
        end
      end
    end
  end
end
