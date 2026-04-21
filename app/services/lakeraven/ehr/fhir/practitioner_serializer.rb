# frozen_string_literal: true

module Lakeraven
  module EHR
    module FHIR
      class PractitionerSerializer
        US_CORE_PROFILE = "http://hl7.org/fhir/us/core/StructureDefinition/us-core-practitioner"

        def self.call(practitioner)
          new(practitioner).to_h
        end

        def initialize(practitioner)
          @p = practitioner
        end

        def to_h
          resource = {
            resourceType: "Practitioner",
            id: @p.ien.to_s,
            meta: { profile: [ US_CORE_PROFILE ] },
            name: [ build_name ]
          }

          ids = build_identifiers
          resource[:identifier] = ids if ids.any?

          telecoms = build_telecoms
          resource[:telecom] = telecoms if telecoms.any?

          quals = build_qualifications
          resource[:qualification] = quals if quals.any?

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

        def build_identifiers
          ids = []
          if @p.npi.present?
            ids << { system: "http://hl7.org/fhir/sid/us-npi", value: @p.npi }
          end
          if @p.ien.present?
            ids << { use: "usual", system: "http://ihs.gov/rpms/provider-id", value: @p.ien.to_s }
          end
          ids
        end

        def build_telecoms
          return [] if @p.phone.blank?
          [ { system: "phone", value: @p.phone, use: "work" } ]
        end

        def build_qualifications
          return [] if @p.specialty.blank?
          [ { code: { text: @p.specialty } } ]
        end
      end
    end
  end
end
