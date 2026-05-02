# frozen_string_literal: true

module Lakeraven
  module EHR
    module FHIR
      # Serializes Encounter domain object to FHIR R4 Encounter hash.
      # Delegates to Encounter#to_fhir for structure, adds policy filtering.
      class EncounterSerializer
        def initialize(encounter, policy: nil)
          @encounter = encounter
          @policy = policy || RedactionPolicy.new(view: :full)
        end

        def to_h
          resource = @encounter.to_fhir
          @policy.apply(resource)
        end
      end
    end
  end
end
