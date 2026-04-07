# frozen_string_literal: true

module Lakeraven
  module EHR
    module FHIR
      # Serializes an adapter patient hash to a US Core conformant
      # FHIR R4 Patient resource.
      #
      # The input is the public_view shape returned by Adapters::Base
      # implementations: opaque patient_identifier, display_name in
      # "FAMILY,GIVEN" form, date_of_birth, gender, identifiers array.
      #
      # The output is a Hash whose keys are symbols matching the FHIR
      # JSON shape; the controller renders it as application/fhir+json.
      #
      # No PHI persistence happens here per ADR 0002 — this serializer
      # is pure: hash in, hash out.
      class PatientSerializer
        US_CORE_PROFILE = "http://hl7.org/fhir/us/core/StructureDefinition/us-core-patient"

        def self.call(record)
          new(record).to_h
        end

        def initialize(record)
          @record = record
        end

        def to_h
          resource = {
            resourceType: "Patient",
            id: @record[:patient_identifier],
            meta: { profile: [ US_CORE_PROFILE ] },
            name: [ build_name ],
            gender: gender_value
          }
          resource[:birthDate] = format_date(@record[:date_of_birth]) if @record[:date_of_birth]
          identifiers = build_identifiers
          resource[:identifier] = identifiers if identifiers.any?
          resource
        end

        private

        # Parses VistA-style "FAMILY,GIVEN MIDDLE" into a FHIR HumanName.
        # Falls back to a single text element when the value doesn't
        # contain a comma — handles mononyms and adapter-supplied names
        # we don't recognize the format of.
        def build_name
          display = @record[:display_name].to_s
          return { text: display } unless display.include?(",")

          family, rest = display.split(",", 2)
          given = rest.to_s.strip.split(/\s+/).reject(&:empty?)
          { family: family, given: given }
        end

        # FHIR R4 administrative-gender code set: male | female | other |
        # unknown. The adapter is expected to supply one of these; if
        # something else (or nil) comes through, render as "unknown" so
        # the resource is still valid.
        def gender_value
          value = @record[:gender].to_s
          %w[male female other unknown].include?(value) ? value : "unknown"
        end

        def format_date(date)
          date.is_a?(Date) ? date.iso8601 : Date.parse(date.to_s).iso8601
        end

        def build_identifiers
          (@record[:identifiers] || []).map do |id|
            { system: id[:system], value: id[:value] }
          end
        end
      end
    end
  end
end
