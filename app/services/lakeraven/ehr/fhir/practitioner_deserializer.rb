# frozen_string_literal: true

module Lakeraven
  module EHR
    module FHIR
      # Extracts Practitioner attributes from a FHIR R4 Practitioner resource
      # (Hash or object with dot-access). Returns a plain Hash suitable for
      # Practitioner.new(attrs).
      class PractitionerDeserializer
        NPI_SYSTEM = "http://hl7.org/fhir/sid/us-npi"
        DEA_SYSTEM = "http://hl7.org/fhir/sid/us-dea"

        def self.call(fhir_resource)
          new(fhir_resource).extract
        end

        def initialize(fhir_resource)
          @r = fhir_resource
        end

        def extract
          {
            name: extract_name,
            npi: extract_identifier(NPI_SYSTEM),
            dea_number: extract_identifier(DEA_SYSTEM),
            gender: map_gender,
            specialty: extract_specialty
          }.compact
        end

        private

        def extract_name
          names = dig(:name)
          return nil unless names.is_a?(Array) && names.any?

          name_obj = names.first
          text = dig_from(name_obj, :text)
          return text if text.present?

          family = dig_from(name_obj, :family)
          given = dig_from(name_obj, :given)
          given_str = given.is_a?(Array) ? given.join(" ") : given

          if family.present? && given_str.present?
            "#{family},#{given_str}"
          elsif family.present?
            family
          elsif given_str.present?
            given_str
          end
        end

        def extract_identifier(system_uri)
          ids = dig(:identifier)
          return nil unless ids.is_a?(Array)

          match = ids.find { |id| dig_from(id, :system).to_s == system_uri }
          dig_from(match, :value)
        end

        def map_gender
          raw = dig(:gender).to_s.downcase
          case raw
          when "male" then "M"
          when "female" then "F"
          when "" then nil
          end
        end

        def extract_specialty
          quals = dig(:qualification)
          return nil unless quals.is_a?(Array) && quals.any?

          code = dig_from(quals.first, :code)
          return nil unless code

          dig_from(code, :text)
        end

        # Flexible accessor: supports both Hash (symbol/string) and
        # dot-access objects (OpenStruct, FHIR models).
        def dig(key)
          if @r.is_a?(Hash)
            @r[key.to_sym] || @r[key.to_s]
          elsif @r.respond_to?(key)
            @r.send(key)
          end
        end

        def dig_from(obj, key)
          return nil unless obj
          if obj.is_a?(Hash)
            obj[key.to_sym] || obj[key.to_s]
          elsif obj.respond_to?(key)
            obj.send(key)
          end
        end
      end
    end
  end
end
