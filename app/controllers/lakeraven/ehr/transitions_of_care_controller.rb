# frozen_string_literal: true

module Lakeraven
  module EHR
    # ONC §170.315(b)(1) — Transitions of Care (send path)
    # Generates C-CDA documents for patient care transitions.
    class TransitionsOfCareController < ApplicationController
      include PatientCompartment

      # This POST RETURNS the patient's chart as a C-CDA, so it needs read
      # scope as well as write, and it is bound to the patient compartment
      # like any other read of that patient.
      discloses_clinical_data :create
      compartment_bound :create, param: :patient_dfn

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
          author: ccda_author
        )

        render xml: ccda_xml, status: :created, content_type: "application/xml"
      end

      private

      # WHO authored this document.
      #
      # A C-CDA is a clinical-legal artifact, so its author is an attestation,
      # and an attestation read off a request parameter is a forgery waiting to
      # happen — `author_name=FORGED,AUTHOR` landed in the artifact verbatim.
      # The identity a request acts under comes from the TOKEN, never from the
      # body.
      #
      # The document must never NAME a human it cannot vouch for. When a
      # clinician identity is resolvable the author is that clinician; when it
      # is not, the author is the authenticated client as an authoring DEVICE,
      # with no person's name on it. Both are non-forgeable; neither invents a
      # human.
      #
      # NOTE: `current_duz` / `current_user_name` are defined by the
      # session-bridge work (#486) and are NOT on this branch. `respond_to?`
      # is false here until that lands, which yields the device attribution —
      # correct on this base, and it sharpens to the clinician automatically
      # once the bridge exists. Do not simplify this away when #486 lands.
      def ccda_author
        duz = respond_to?(:current_duz, true) ? current_duz.presence : nil
        if duz.present?
          name = respond_to?(:current_user_name, true) ? current_user_name : nil
          return { name: name, npi: nil, duz: duz }
        end

        { name: nil, npi: nil, institution: nil, device: current_token&.application&.name }
      end
    end
  end
end
