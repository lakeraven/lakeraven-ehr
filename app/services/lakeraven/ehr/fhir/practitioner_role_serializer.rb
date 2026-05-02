# frozen_string_literal: true

module Lakeraven
  module EHR
    module FHIR
      class PractitionerRoleSerializer
        def initialize(model, policy: nil)
          @model = model
          @policy = policy || RedactionPolicy.new(view: :full)
        end

        def to_h
          @policy.apply(@model.to_fhir)
        end
      end
    end
  end
end
