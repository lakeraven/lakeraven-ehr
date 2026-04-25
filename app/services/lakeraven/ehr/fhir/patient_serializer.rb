# frozen_string_literal: true

module Lakeraven
  module EHR
    module FHIR
      # Serializes a Patient model to a US Core conformant FHIR R4 Patient hash.
      class PatientSerializer
        US_CORE_PROFILE = "http://hl7.org/fhir/us/core/StructureDefinition/us-core-patient"

        # CDC Race & Ethnicity code system OID
        RACE_CODE_SYSTEM = "urn:oid:2.16.840.1.113883.6.238"

        # Map RPMS race values to CDC Race & Ethnicity codes
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

        def self.call(patient)
          new(patient).to_h
        end

        def initialize(patient)
          @p = patient
        end

        def to_h
          resource = {
            resourceType: "Patient",
            id: @p.dfn.to_s,
            meta: { profile: [ US_CORE_PROFILE ] },
            name: [ build_name ],
            gender: gender_value
          }
          resource[:birthDate] = @p.dob.iso8601 if @p.dob

          ids = build_identifiers
          resource[:identifier] = ids if ids.any?

          addrs = build_addresses
          resource[:address] = addrs if addrs.any?

          telecoms = build_telecoms
          resource[:telecom] = telecoms if telecoms.any?

          exts = build_extensions
          resource[:extension] = exts if exts.any?

          resource
        end

        private

        def build_name
          return {} if @p.name.blank?

          parts = @p.name.split(",")
          family = parts[0]&.strip
          given = parts[1]&.strip&.split(" ") || []
          { use: "official", family: family, given: given }
        end

        def gender_value
          case @p.sex
          when "M" then "male"
          when "F" then "female"
          else "unknown"
          end
        end

        def build_identifiers
          ids = []
          ids << { use: "usual", system: "urn:oid:2.16.840.1.113883.4.349", value: @p.dfn.to_s } if @p.dfn.present?
          ids << { use: "secondary", system: "http://hl7.org/fhir/sid/us-ssn", value: @p.ssn } if @p.ssn.present?
          ids
        end

        def build_addresses
          return [] if @p.address_line1.blank?

          [ { use: "home", line: [ @p.address_line1 ], city: @p.city,
             state: @p.state, postalCode: @p.zip_code, country: "US" }.compact ]
        end

        def build_telecoms
          return [] if @p.phone.blank?

          [ { system: "phone", value: @p.phone, use: "home" } ]
        end

        def build_extensions
          exts = []

          # US Core Race extension (complex extension per US Core spec)
          exts << build_race_extension if @p.race.present?

          # US Core Ethnicity extension (Inferno requires this)
          exts << build_ethnicity_extension

          # Tribal affiliation
          if @p.tribal_enrollment_number.present?
            exts << {
              url: "http://hl7.org/fhir/us/core/StructureDefinition/tribal-affiliation",
              valueString: @p.tribal_enrollment_number
            }
          end

          # SOGI extensions (USCDI v3 / ONC 170.315(a)(15))
          if @p.respond_to?(:sexual_orientation) && @p.sexual_orientation.present?
            exts << {
              url: "http://hl7.org/fhir/StructureDefinition/patient-sexualOrientation",
              valueString: @p.sexual_orientation
            }
          end

          if @p.respond_to?(:gender_identity) && @p.gender_identity.present?
            exts << {
              url: "http://hl7.org/fhir/StructureDefinition/patient-genderIdentity",
              valueString: @p.gender_identity
            }
          end

          exts
        end

        def build_race_extension
          race_upper = @p.race.upcase.strip
          mapped = RACE_CODE_MAP[race_upper]
          sub_extensions = []

          if mapped
            sub_extensions << {
              url: "ombCategory",
              valueCoding: {
                system: RACE_CODE_SYSTEM,
                code: mapped[:code],
                display: mapped[:display]
              }
            }
            sub_extensions << { url: "text", valueString: mapped[:display] }
          else
            sub_extensions << { url: "text", valueString: @p.race }
          end

          {
            url: "http://hl7.org/fhir/us/core/StructureDefinition/us-core-race",
            extension: sub_extensions
          }
        end

        def build_ethnicity_extension
          {
            url: "http://hl7.org/fhir/us/core/StructureDefinition/us-core-ethnicity",
            extension: [
              { url: "text", valueString: "Unknown" }
            ]
          }
        end
      end
    end
  end
end
