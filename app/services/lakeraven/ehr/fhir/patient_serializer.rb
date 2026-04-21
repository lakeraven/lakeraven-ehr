# frozen_string_literal: true

module Lakeraven
  module EHR
    module FHIR
      # Serializes a Patient model to a US Core conformant FHIR R4 Patient hash.
      class PatientSerializer
        US_CORE_PROFILE = "http://hl7.org/fhir/us/core/StructureDefinition/us-core-patient"

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
      end
    end
  end
end
