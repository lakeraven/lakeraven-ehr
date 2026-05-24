# frozen_string_literal: true

module Lakeraven
  module EHR
    # ONC §170.315(b)(1) — Transitions of Care (send path)
    # Generates C-CDA documents for patient care transitions.
    class TransitionsOfCareController < ApplicationController
      # POST /transitions_of_care
      def create
        patient = Patient.find_by_dfn(params[:patient_dfn])
        unless patient
          return render_not_found("Patient", params[:patient_dfn])
        end

        # The clinical *.for_patient methods may return either model instances
        # or raw attribute hashes depending on whether the gateway has been
        # updated to wrap responses. Read defensively until #233 normalizes.
        attr = ->(item, key) { item.is_a?(Hash) ? item[key] : item.public_send(key) }

        allergies = (AllergyIntolerance.for_patient(params[:patient_dfn]) rescue [])
          .map { |a| { code: attr.call(a, :allergen_code), display: attr.call(a, :allergen), code_system: nil } }
        conditions = (Condition.for_patient(params[:patient_dfn]) rescue [])
          .map { |c| { code: attr.call(c, :code), display: attr.call(c, :display), code_system: attr.call(c, :code_system) } }
        medications = (MedicationRequest.for_patient(params[:patient_dfn]) rescue [])
          .map { |m| { code: attr.call(m, :medication_code), display: attr.call(m, :medication_display), code_system: nil } }

        # CcdaGenerator expects hashes until #233 is resolved
        name_parts = patient.name.to_s.split(",", 2)
        patient_hash = {
          dfn: patient.dfn.to_s,
          name: { family: name_parts[0]&.strip, given: name_parts[1]&.strip },
          dob: patient.dob,
          sex: patient.sex,
          address: { street: patient.address_line1, city: patient.city, state: patient.state, zip: patient.zip_code }
        }

        ccda_xml = CcdaGenerator.generate(
          patient: patient_hash,
          allergies: allergies,
          conditions: conditions,
          medications: medications,
          author: { name: params[:author_name], npi: params[:author_npi] }
        )

        render xml: ccda_xml, status: :created, content_type: "application/xml"
      end
    end
  end
end
