# frozen_string_literal: true

module Lakeraven
  module EHR
    module FHIR
      # Extracts Patient attributes from a FHIR R4 Patient resource (Hash
      # or object with dot-access). Returns a plain Hash suitable for
      # Patient.new(attrs).
      class PatientDeserializer
        def self.call(fhir_resource)
          new(fhir_resource).extract
        end

        def initialize(fhir_resource)
          @r = fhir_resource
        end

        def extract
          {
            name: extract_name,
            dob: extract_birth_date,
            birth_date: extract_birth_date,
            sex: map_gender_to_sex,
            ssn: extract_ssn
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

        def extract_birth_date
          val = dig(:birthDate)
          val.present? ? Date.parse(val.to_s) : nil
        rescue Date::Error
          nil
        end

        def map_gender_to_sex
          case dig(:gender).to_s.downcase
          when "male" then "M"
          when "female" then "F"
          else "U"
          end
        end

        SSN_SYSTEM = "http://hl7.org/fhir/sid/us-ssn"

        def extract_ssn
          ids = dig(:identifier)
          return nil unless ids.is_a?(Array)

          ssn_id = ids.find { |id| dig_from(id, :system).to_s == SSN_SYSTEM }
          dig_from(ssn_id, :value)
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
