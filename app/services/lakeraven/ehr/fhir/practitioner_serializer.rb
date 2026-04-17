# frozen_string_literal: true

module Lakeraven
  module EHR
    module FHIR
      # Serializes an adapter practitioner hash to a US Core conformant
      # FHIR R4 Practitioner resource.
      #
      # The input is a Hash with symbol keys matching the adapter's
      # public_view shape. All keys are optional except :display_name.
      #
      # No PHI persistence happens here per ADR 0002 — pure transform.
      class PractitionerSerializer
        US_CORE_PROFILE = "http://hl7.org/fhir/us/core/StructureDefinition/us-core-practitioner"

        NPI_SYSTEM = "http://hl7.org/fhir/sid/us-npi"
        DEA_SYSTEM = "http://hl7.org/fhir/sid/us-dea"
        IEN_SYSTEM = "http://ihs.gov/rpms/provider-id"

        def self.call(record)
          new(record).to_h
        end

        def initialize(record)
          @record = record
        end

        def to_h
          resource = {
            resourceType: "Practitioner",
            id: @record[:practitioner_identifier],
            meta: { profile: [ US_CORE_PROFILE ] },
            name: [ build_name ],
            gender: gender_value
          }

          identifiers = build_identifiers
          resource[:identifier] = identifiers if identifiers.any?

          qualifications = build_qualifications
          resource[:qualification] = qualifications if qualifications.any?

          telecoms = build_telecoms
          resource[:telecom] = telecoms if telecoms.any?

          resource.compact
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

        def gender_value
          raw = @record[:gender].to_s
          return "male" if raw == "M"
          return "female" if raw == "F"
          return raw if %w[male female other unknown].include?(raw)
          nil
        end

        # ----------------------------------------------------------------
        # Identifiers
        # ----------------------------------------------------------------

        def build_identifiers
          ids = (@record[:identifiers] || []).map do |id|
            { system: id[:system], value: id[:value] }
          end

          if @record[:npi].present?
            ids << { use: "official", system: NPI_SYSTEM, value: @record[:npi] }
          end

          if @record[:dea_number].present?
            ids << { use: "official", system: DEA_SYSTEM, value: @record[:dea_number] }
          end

          if @record[:ien].present?
            ids << { use: "usual", system: IEN_SYSTEM, value: @record[:ien].to_s }
          end

          ids
        end

        # ----------------------------------------------------------------
        # Qualifications (specialty, provider class, title)
        # ----------------------------------------------------------------

        def build_qualifications
          quals = []

          if @record[:specialty].present?
            quals << {
              code: { text: @record[:specialty] }
            }
          end

          if @record[:provider_class].present?
            quals << {
              code: { text: @record[:provider_class] }
            }
          end

          quals
        end

        # ----------------------------------------------------------------
        # Telecom
        # ----------------------------------------------------------------

        def build_telecoms
          return [] if @record[:phone].blank?

          [ { system: "phone", value: @record[:phone], use: "work" } ]
        end
      end
    end
  end
end
