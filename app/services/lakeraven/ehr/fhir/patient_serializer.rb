# frozen_string_literal: true

module Lakeraven
  module EHR
    module FHIR
      # Serializes an adapter patient hash to a US Core conformant
      # FHIR R4 Patient resource with IHS tribal and SOGI extensions.
      #
      # The input is a Hash with symbol keys matching the adapter's
      # public_view shape. All keys are optional except :display_name.
      #
      # No PHI persistence happens here per ADR 0002 — pure transform.
      class PatientSerializer
        US_CORE_PROFILE = "http://hl7.org/fhir/us/core/StructureDefinition/us-core-patient"

        # CDC Race & Ethnicity code system OID
        RACE_CODE_SYSTEM = "urn:oid:2.16.840.1.113883.6.238"

        RACE_CODE_MAP = {
          "AMERICAN INDIAN OR ALASKA NATIVE" => { code: "1002-5", display: "American Indian or Alaska Native" },
          "AMERICAN INDIAN" => { code: "1002-5", display: "American Indian or Alaska Native" },
          "ALASKA NATIVE" => { code: "1002-5", display: "American Indian or Alaska Native" },
          "ASIAN" => { code: "2028-9", display: "Asian" },
          "BLACK OR AFRICAN AMERICAN" => { code: "2054-5", display: "Black or African American" },
          "BLACK" => { code: "2054-5", display: "Black or African American" },
          "NATIVE HAWAIIAN OR OTHER PACIFIC ISLANDER" => { code: "2076-8", display: "Native Hawaiian or Other Pacific Islander" },
          "WHITE" => { code: "2106-3", display: "White" },
          "OTHER" => { code: "2131-1", display: "Other Race" },
          "UNKNOWN" => { code: "UNK", display: "Unknown" }
        }.freeze

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

          addresses = build_addresses
          resource[:address] = addresses if addresses.any?

          telecoms = build_telecoms
          resource[:telecom] = telecoms if telecoms.any?

          extensions = build_extensions
          resource[:extension] = extensions if extensions.any?

          resource
        end

        private

        # ----------------------------------------------------------------
        # Name
        # ----------------------------------------------------------------

        def build_name
          pn = PatientName.new(name: @record[:display_name])
          pn.to_fhir
        end

        # ----------------------------------------------------------------
        # Gender
        # ----------------------------------------------------------------

        # FHIR R4 administrative-gender: male | female | other | unknown.
        # VistA/RPMS uses single-char M/F/U — map those to FHIR codes.
        # Anything already in the FHIR code set passes through; anything
        # else normalizes to "unknown" so the resource always validates.
        def gender_value
          raw = (@record[:gender] || @record[:sex]).to_s
          # VistA single-char codes
          return "male" if raw == "M"
          return "female" if raw == "F"
          # Already FHIR-compliant (lowercase)
          return raw if %w[male female other unknown].include?(raw)
          "unknown"
        end

        # ----------------------------------------------------------------
        # Identifiers
        # ----------------------------------------------------------------

        def build_identifiers
          ids = (@record[:identifiers] || []).map do |id|
            { system: id[:system], value: id[:value] }
          end

          # DFN identifiers (VA OID + IHS system)
          if @record[:dfn].present?
            ids << { use: "usual",
                     system: "urn:oid:2.16.840.1.113883.4.349",
                     value: @record[:dfn].to_s }
            ids << { use: "official",
                     system: "http://ihs.gov/rpms/patient-id",
                     value: @record[:dfn].to_s }
          end

          # SSN
          if @record[:ssn].present?
            ids << { use: "secondary",
                     system: "http://hl7.org/fhir/sid/us-ssn",
                     value: @record[:ssn] }
          end

          ids
        end

        # ----------------------------------------------------------------
        # Address
        # ----------------------------------------------------------------

        def build_addresses
          addr = @record[:address_line1]
          return [] if addr.blank?

          [ { use: "home",
              line: [ addr ],
              city: @record[:city],
              state: @record[:state],
              postalCode: @record[:zip_code],
              country: "US" }.compact ]
        end

        # ----------------------------------------------------------------
        # Telecom
        # ----------------------------------------------------------------

        def build_telecoms
          return [] if @record[:phone].blank?

          [ { system: "phone", value: @record[:phone], use: "home" } ]
        end

        # ----------------------------------------------------------------
        # Extensions
        # ----------------------------------------------------------------

        def build_extensions
          exts = []

          exts << build_us_core_race if @record[:race].present?
          exts << build_us_core_ethnicity
          exts << simple_extension("https://ihs.gov/fhir/StructureDefinition/tribal-affiliation",
            @record[:tribal_affiliation])
          exts << simple_extension("https://ihs.gov/fhir/StructureDefinition/tribal-enrollment-number",
            @record[:tribal_enrollment_number])
          exts << simple_extension("http://hl7.org/fhir/StructureDefinition/patient-sexualOrientation",
            @record[:sexual_orientation])
          exts << simple_extension("http://hl7.org/fhir/StructureDefinition/patient-genderIdentity",
            @record[:gender_identity])

          exts.compact
        end

        def build_us_core_race
          race_upper = @record[:race].to_s.upcase.strip
          mapped = RACE_CODE_MAP[race_upper]

          sub = []
          if mapped
            sub << { url: "ombCategory",
                     valueCoding: { system: RACE_CODE_SYSTEM,
                                    code: mapped[:code],
                                    display: mapped[:display] } }
            sub << { url: "text", valueString: mapped[:display] }
          else
            sub << { url: "text", valueString: @record[:race] }
          end

          { url: "http://hl7.org/fhir/us/core/StructureDefinition/us-core-race",
            extension: sub }
        end

        def build_us_core_ethnicity
          { url: "http://hl7.org/fhir/us/core/StructureDefinition/us-core-ethnicity",
            extension: [ { url: "text", valueString: "Unknown" } ] }
        end

        def simple_extension(url, value)
          return nil if value.blank?
          { url: url, valueString: value }
        end

        # ----------------------------------------------------------------
        # Utilities
        # ----------------------------------------------------------------

        def format_date(date)
          date.is_a?(Date) ? date.iso8601 : Date.parse(date.to_s).iso8601
        end
      end
    end
  end
end
