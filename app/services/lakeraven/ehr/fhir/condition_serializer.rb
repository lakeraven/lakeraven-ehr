# frozen_string_literal: true

require "ostruct"

module Lakeraven
  module EHR
    module FHIR
      # Serializes a Problem/Condition domain object to FHIR R4 Condition hash.
      # Integrates terminology decorators for coded diagnoses.
      class ConditionSerializer
        CLINICAL_STATUS_MAP = {
          "A" => { code: "active", display: "Active" },
          "I" => { code: "inactive", display: "Inactive" },
          "R" => { code: "resolved", display: "Resolved" }
        }.freeze

        def initialize(condition, policy: nil)
          @c = condition
          @policy = policy || RedactionPolicy.new(view: :full)
        end

        def to_h
          resource = {
            resourceType: "Condition",
            id: @c.ien.to_s,
            clinicalStatus: build_clinical_status,
            code: build_code,
            subject: { reference: "Patient/#{@c.patient_dfn}" }
          }

          resource[:onsetDateTime] = @c.onset_date.iso8601 if @c.onset_date
          resource[:recordedDate] = @c.recorded_date.iso8601 if @c.respond_to?(:recorded_date) && @c.recorded_date

          @policy.apply(resource)
        end

        private

        def build_clinical_status
          mapped = CLINICAL_STATUS_MAP[@c.status] || { code: "unknown", display: "Unknown" }
          {
            coding: [ {
              system: "http://terminology.hl7.org/CodeSystem/condition-clinical",
              code: mapped[:code],
              display: mapped[:display]
            } ]
          }
        end

        def build_code
          codings = []

          if @c.icd_code.present?
            icd = Terminology::ICD10.new(@c.icd_code)
            codings << icd.to_coding
          end

          if @c.respond_to?(:snomed_code) && @c.snomed_code.present?
            snomed = Terminology::SNOMED.new(@c.snomed_code)
            codings << snomed.to_coding
          end

          text = @c.respond_to?(:description) ? @c.description : nil

          { coding: codings, text: text }.compact
        end
      end
    end
  end
end
