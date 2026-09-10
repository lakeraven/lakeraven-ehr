# frozen_string_literal: true

module Lakeraven
  module EHR
    module FHIR
      # Serializes a persisted ScreeningResponse to a FHIR R4
      # QuestionnaireResponse — the item-level record of what the patient
      # actually answered, as distinct from the Observation that carries the
      # trendable total.
      #
      # linkIds are the items' LOINC codes and the questionnaire canonical is
      # LOINC's own `http://loinc.org/q/<panel-code>`, so the response resolves
      # against the published LOINC Questionnaire with no local mapping table.
      # Answer codings come from LOINC answer list LL358-3.
      class QuestionnaireResponseSerializer
        STATUS_COMPLETED = "completed"

        def initialize(screening_response)
          @r = screening_response
        end

        def to_h
          {
            resourceType: "QuestionnaireResponse",
            id: @r.id&.to_s,
            questionnaire: instrument.questionnaire_canonical,
            status: STATUS_COMPLETED,
            subject: { reference: "Patient/#{@r.patient_dfn}" },
            encounter: encounter_reference,
            authored: @r.effective_at&.iso8601,
            author: author_reference,
            item: items
          }.compact
        end

        private

        def instrument = @r.instrument

        def encounter_reference
          return nil if @r.encounter_ien.blank?

          { reference: "Encounter/#{@r.encounter_ien}" }
        end

        # Only a clinician administration has a Practitioner author; a
        # pre-visit self-report is authored by the patient (#471).
        def author_reference
          if @r.source == ScreeningResponse::SOURCE_PRE_VISIT
            { reference: "Patient/#{@r.patient_dfn}" }
          elsif @r.administered_by.present?
            { reference: "Practitioner/#{@r.administered_by}" }
          end
        end

        def items
          @r.answered_items.map do |item, choice|
            {
              linkId: item.link_id,
              text: item.text,
              answer: [ { valueCoding: answer_coding(choice) } ]
            }
          end
        end

        # Terminology::LOINC supplies the system URI (the engine's single
        # source of truth for it); the human-readable display comes from the
        # instrument definition, since the mapper defaults display to the code.
        def answer_coding(choice)
          Terminology::LOINC.new(choice.link_id).to_coding.merge(display: choice.text)
        end
      end
    end
  end
end
