# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # The FHIR face of a stored screening: a QuestionnaireResponse for the
    # item-level answers and an Observation for the trendable total.
    class ScreeningResponseFhirTest < ActiveSupport::TestCase
      PHQ9 = ScreeningInstrument::PHQ9
      GAD7 = ScreeningInstrument::GAD7

      teardown { ScreeningResponse.delete_all }

      def record(instrument: PHQ9, ordinals: nil, **overrides)
        values = ordinals || Array.new(instrument.items.length, 1)
        ScreeningResponse.create!({
          patient_dfn: 1,
          encounter_ien: "2090061",
          instrument_key: instrument.key,
          answers: instrument.link_ids.zip(values).to_h,
          total_score: values.sum,
          severity_band: instrument.band_label_for(values.sum),
          effective_at: Time.utc(2026, 3, 1, 14, 30),
          administered_by: "99999",
          source: ScreeningResponse::SOURCE_CLINICIAN
        }.merge(overrides))
      end

      # -- Observation (the trendable total) -----------------------------------

      test "the total score serializes as a coded, dated Observation" do
        fhir = record.to_observation.to_fhir

        assert_equal "Observation", fhir[:resourceType]
        assert_equal "final", fhir[:status]
        assert_equal "Patient/1", fhir.dig(:subject, :reference)
        # The TOTAL SCORE code (44261-6), not the panel code (44249-1).
        assert_equal "44261-6", fhir.dig(:code, :coding, 0, :code)
        assert_equal "http://loinc.org", fhir.dig(:code, :coding, 0, :system)
        assert_equal "2026-03-01T14:30:00Z", fhir[:effectiveDateTime]
      end

      test "GAD-7 uses its own LOINC total score code" do
        fhir = record(instrument: GAD7).to_observation.to_fhir

        assert_equal "70274-6", fhir.dig(:code, :coding, 0, :code)
      end

      test "the score is a numeric quantity, not a string or a note" do
        fhir = record(ordinals: [ 3, 2, 2, 2, 1, 1, 1, 0, 0 ]).to_observation.to_fhir

        assert_equal 12.0, fhir.dig(:valueQuantity, :value)
        assert_kind_of Numeric, fhir.dig(:valueQuantity, :value)
        assert_equal "{score}", fhir.dig(:valueQuantity, :code)
        assert_equal "http://unitsofmeasure.org", fhir.dig(:valueQuantity, :system)
        assert_nil fhir[:valueString]
      end

      test "the observation is categorised as a survey with the US Core screening profile" do
        fhir = record.to_observation.to_fhir

        assert_equal "survey", fhir.dig(:category, 0, :coding, 0, :code)
        assert_includes fhir.dig(:meta, :profile),
                        "http://hl7.org/fhir/us/core/StructureDefinition/us-core-observation-screening-assessment"
      end

      test "the observation id is deterministic, not random" do
        stored = record

        assert_equal "screening-phq-9-#{stored.id}", stored.to_observation.to_fhir[:id]
        assert_equal stored.to_observation.to_fhir[:id], stored.reload.to_observation.to_fhir[:id]
      end

      # -- QuestionnaireResponse (the item-level answers) ----------------------

      test "answers serialize as a QuestionnaireResponse against the LOINC questionnaire" do
        fhir = record.to_questionnaire_response

        assert_equal "QuestionnaireResponse", fhir[:resourceType]
        assert_equal "completed", fhir[:status]
        assert_equal "http://loinc.org/q/44249-1", fhir[:questionnaire]
        assert_equal "Patient/1", fhir.dig(:subject, :reference)
        assert_equal "Encounter/2090061", fhir.dig(:encounter, :reference)
        assert_equal "2026-03-01T14:30:00Z", fhir[:authored]
      end

      test "every answered item appears once, keyed by its LOINC link id" do
        fhir = record.to_questionnaire_response

        assert_equal 9, fhir[:item].length
        assert_equal PHQ9.link_ids, fhir[:item].map { |i| i[:linkId] }
      end

      test "answers carry the LOINC answer-list coding and its display" do
        fhir = record(ordinals: [ 0, 1, 2, 3, 0, 0, 0, 0, 0 ]).to_questionnaire_response
        codings = fhir[:item].first(4).map { |i| i.dig(:answer, 0, :valueCoding) }

        assert_equal %w[LA6568-5 LA6569-3 LA6570-1 LA6571-9], codings.map { |c| c[:code] }
        assert_equal [ "http://loinc.org" ] * 4, codings.map { |c| c[:system] }
        assert_equal "Not at all", codings.first[:display]
        assert_equal "Nearly every day", codings.last[:display]
      end

      test "item text travels with the answer so the response reads standalone" do
        fhir = record.to_questionnaire_response

        assert_equal "Little interest or pleasure in doing things", fhir[:item].first[:text]
      end

      test "a clinician administration is authored by the practitioner" do
        assert_equal "Practitioner/99999", record.to_questionnaire_response.dig(:author, :reference)
      end

      test "a pre-visit self-report is authored by the patient and carries no encounter" do
        fhir = record(source: ScreeningResponse::SOURCE_PRE_VISIT,
                      administered_by: nil, encounter_ien: nil).to_questionnaire_response

        assert_equal "Patient/1", fhir.dig(:author, :reference)
        assert_nil fhir[:encounter]
      end

      test "both resources are available together" do
        types = record.to_fhir_resources.map { |r| r[:resourceType] }

        assert_equal %w[QuestionnaireResponse Observation], types
      end

      # -- Validation ----------------------------------------------------------

      test "an unscored screening cannot be stored" do
        assert_raises(ActiveRecord::RecordInvalid) do
          ScreeningResponse.create!(patient_dfn: 1, instrument_key: "phq-9", answers: {},
                                    total_score: nil, severity_band: nil, effective_at: Time.current)
        end
      end

      test "an unknown instrument cannot be stored" do
        invalid = ScreeningResponse.new(patient_dfn: 1, instrument_key: "phq-2", answers: {},
                                        total_score: 1, severity_band: "mild", effective_at: Time.current)

        assert_not invalid.valid?
        assert_includes invalid.errors[:instrument_key], "is not included in the list"
      end

      test "screenings for a patient come back oldest first for trending" do
        record(effective_at: Time.utc(2026, 5, 1))
        record(effective_at: Time.utc(2026, 3, 1))
        record(effective_at: Time.utc(2026, 4, 1))

        months = ScreeningResponse.for_patient(1).map { |r| r.effective_at.month }
        assert_equal [ 3, 4, 5 ], months
      end
    end
  end
end
