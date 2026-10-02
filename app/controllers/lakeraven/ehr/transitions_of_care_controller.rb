# frozen_string_literal: true

module Lakeraven
  module EHR
    # ONC §170.315(b)(1) — Transitions of Care (send path)
    # Generates C-CDA documents for patient care transitions.
    class TransitionsOfCareController < ApplicationController
      include PatientCompartment

      # Types in the C-CDA body. A scope named after this controller is not
      # one of them.
      DISCLOSED_TYPES = %w[Patient AllergyIntolerance Condition MedicationRequest].freeze
      EGRESS_LISTS = %i[allergies conditions medications].freeze

      # This POST RETURNS the patient's chart as a C-CDA, so it needs read
      # scope as well as write, and it is bound to the patient compartment
      # like any other read of that patient.
      discloses_clinical_data :create, reads: DISCLOSED_TYPES
      compartment_bound :create, param: :patient_dfn

      # POST /transitions_of_care
      def create
        patient = Patient.find_by_dfn(params[:patient_dfn])
        return render_not_found("Patient", params[:patient_dfn]) unless patient

        filtered = Part2EgressFilter.call(egress_sections(patient))
        return refuse_unfiltered_egress unless egress_sections?(filtered)

        render xml: renderable_ccda(filtered), status: :created, content_type: "application/xml"
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

      def egress_sections(patient)
        dfn = params[:patient_dfn]
        {
          patient: patient_demographics(patient),
          allergies: coded_rows(AllergyIntolerance, dfn, :allergen_code, :allergen),
          conditions: coded_rows(Condition, dfn, :code, :display, :code_system),
          medications: coded_rows(MedicationRequest, dfn, :medication_code, :medication_display)
        }
      end

      def patient_demographics(patient)
        family, given = patient.name.to_s.split(",", 2)
        {
          dfn: patient.dfn.to_s,
          name: { family: family&.strip, given: given&.strip },
          dob: patient.dob,
          sex: patient.sex,
          address: address_hash(patient)
        }
      end

      def address_hash(patient)
        {
          street: patient.address_line1,
          city: patient.city,
          state: patient.state,
          zip: patient.zip_code
        }
      end

      # for_patient may raise, or return something other than an array,
      # until #233. An unreadable section becomes []. That empty array is
      # not a claim that the patient has no such records.
      def coded_rows(model, dfn, code_key, display_key, system_key = nil)
        rows = model.for_patient(dfn)
        rows = [] unless rows.is_a?(Array)
        rows.map { |item| coded_row(item, code_key, display_key, system_key) }
      rescue StandardError
        []
      end

      def coded_row(item, code_key, display_key, system_key)
        {
          code: item_value(item, code_key),
          display: item_value(item, display_key),
          code_system: system_key ? item_value(item, system_key) : nil
        }
      end

      def item_value(item, key)
        item.is_a?(Hash) ? item[key] : item.public_send(key)
      end

      def egress_sections?(filtered)
        return false unless filtered.is_a?(Hash) && filtered[:patient].is_a?(Hash)

        EGRESS_LISTS.all? { |key| filtered[key].is_a?(Array) }
      end

      def renderable_ccda(sections)
        CcdaGenerator.generate(
          patient: sections[:patient],
          allergies: sections[:allergies],
          conditions: sections[:conditions],
          medications: sections[:medications],
          author: ccda_author
        )
      end

      def refuse_unfiltered_egress
        render_operation_outcome(
          status: :service_unavailable,
          severity: "error",
          code: "exception",
          diagnostics: "Part 2 egress filter did not return clinical sections; C-CDA not generated"
        )
      end
    end
  end
end
