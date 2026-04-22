# frozen_string_literal: true

module Lakeraven
  module EHR
    class PatientDecorator < BaseDecorator
      supplement_model PatientSupplement
      supplement_key :patient_dfn, from: :dfn

      supplement_field :sexual_orientation
      supplement_field :gender_identity

      def to_fhir
        fhir = model.to_fhir

        extensions = build_sogi_extensions
        fhir[:extension] = extensions if extensions.any?

        fhir
      end

      private

      def build_sogi_extensions
        exts = []
        if sexual_orientation.present?
          exts << { url: "http://hl7.org/fhir/StructureDefinition/patient-sexualOrientation",
                    valueString: sexual_orientation }
        end
        if gender_identity.present?
          exts << { url: "http://hl7.org/fhir/StructureDefinition/patient-genderIdentity",
                    valueString: gender_identity }
        end
        exts
      end
    end
  end
end
