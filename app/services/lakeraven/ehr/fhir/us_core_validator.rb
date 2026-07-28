# frozen_string_literal: true

module Lakeraven
  module EHR
    module FHIR
      # Raised when a generated FHIR resource does not meet the US Core
      # profile requirements we have chosen to enforce. Messages never
      # contain PHI; they report missing structural elements only.
      class UsCoreValidationError < StandardError
        attr_reader :errors

        def initialize(errors)
          @errors = errors
          super(errors.join("; "))
        end
      end

      # Lightweight US Core conformance validator for the resources this
      # engine produces. It does not replace a full FHIR validator; it
      # guards the adapter boundaries for the profiles we have implemented.
      #
      # The validator is intentionally dependency-free. We evaluated
      # fhir_models and inferno_core but they do not ship with the US Core
      # IG, and running an external HAPI validator inside the engine test
      # suite is too heavy for this stage.
      class UsCoreValidator
        US_CORE_PATIENT = "http://hl7.org/fhir/us/core/StructureDefinition/us-core-patient"
        US_CORE_PRACTITIONER = "http://hl7.org/fhir/us/core/StructureDefinition/us-core-practitioner"
        US_CORE_BLOOD_PRESSURE = "http://hl7.org/fhir/us/core/StructureDefinition/us-core-blood-pressure"

        US_CORE_OBSERVATION_PROFILES = [
          "http://hl7.org/fhir/us/core/StructureDefinition/us-core-blood-pressure",
          "http://hl7.org/fhir/us/core/StructureDefinition/us-core-heart-rate",
          "http://hl7.org/fhir/us/core/StructureDefinition/us-core-body-temperature",
          "http://hl7.org/fhir/us/core/StructureDefinition/us-core-respiratory-rate",
          "http://hl7.org/fhir/us/core/StructureDefinition/us-core-pulse-oximetry",
          "http://hl7.org/fhir/us/core/StructureDefinition/us-core-body-weight",
          "http://hl7.org/fhir/us/core/StructureDefinition/us-core-body-height",
          "http://hl7.org/fhir/us/core/StructureDefinition/us-core-bmi"
        ].freeze

        US_CORE_BIRTHSEX_VALUES = %w[M F UNK].freeze

        def self.validate(resource)
          new(resource).validate
        end

        def self.validate!(resource)
          errors = validate(resource)
          raise UsCoreValidationError, errors if errors.any?

          resource
        end

        def initialize(resource)
          @resource = resource
        end

        def validate
          return [] unless us_core_resource?

          case @resource[:resourceType]
          when "Patient" then validate_patient
          when "Practitioner" then validate_practitioner
          when "Observation" then validate_observation
          when "Condition" then validate_condition
          when "AllergyIntolerance" then validate_allergy_intolerance
          else []
          end
        end

        private

        def us_core_resource?
          profiles = Array(@resource[:meta]&.dig(:profile))
          profiles.any? { |p| p.to_s.start_with?("http://hl7.org/fhir/us/core/StructureDefinition/us-core-") }
        end

        def validate_patient
          errors = []
          errors << "Patient resource must have an id" if blank?(@resource[:id])
          errors << "Patient resource must have a name" if Array(@resource[:name]).empty?
          errors << "Patient resource must have a gender" if blank?(@resource[:gender])
          validate_patient_extensions(errors)
          errors
        end

        def validate_patient_extensions(errors)
          extensions = Array(@resource[:extension])

          race = find_extension(extensions, US_CORE_PATIENT.gsub("patient", "race"))
          ethnicity = find_extension(extensions, US_CORE_PATIENT.gsub("patient", "ethnicity"))
          birthsex = find_extension(extensions, US_CORE_PATIENT.gsub("patient", "birthsex"))

          errors << "Patient resource must include the US Core race extension" unless race
          errors << "Patient resource must include the US Core ethnicity extension" unless ethnicity
          errors << "Patient resource must include the US Core birthsex extension" unless birthsex

          if race
            race_subs = Array(race[:extension])
            unless race_subs.any? { |e| e[:url] == "ombCategory" || e[:url] == "text" }
              errors << "US Core race extension must include ombCategory or text"
            end
          end

          if ethnicity
            eth_subs = Array(ethnicity[:extension])
            unless eth_subs.any? { |e| e[:url] == "ombCategory" || e[:url] == "text" }
              errors << "US Core ethnicity extension must include ombCategory or text"
            end
          end

          if birthsex
            unless US_CORE_BIRTHSEX_VALUES.include?(birthsex[:valueCode].to_s)
              errors << "US Core birthsex extension must have valueCode M, F, or UNK"
            end
          end
        end

        def validate_practitioner
          errors = []
          errors << "Practitioner resource must have an id" if blank?(@resource[:id])
          errors << "Practitioner resource must have a name" if Array(@resource[:name]).empty?

          if Array(@resource[:identifier]).empty?
            errors << "Practitioner resource must have at least one identifier"
          end

          errors
        end

        def validate_observation
          errors = []
          errors << "Observation resource must have an id" if blank?(@resource[:id])
          errors << "Observation resource must have a status" if blank?(@resource[:status])
          errors << "Observation resource must have a code" if @resource[:code].nil? || Array(@resource.dig(:code, :coding)).empty?
          errors << "Observation resource must have a category" if Array(@resource[:category]).empty?
          errors << "Observation resource must have a subject" if @resource[:subject].nil? || blank?(@resource.dig(:subject, :reference))
          errors << "Observation resource must have an effective datetime" if blank?(@resource[:effectiveDateTime]) && @resource[:effectivePeriod].nil?

          if blood_pressure?
            validate_blood_pressure_components(errors)
          elsif @resource[:valueQuantity].nil? && @resource[:valueString].nil? && @resource[:valueCodeableConcept].nil?
            errors << "Observation resource must have a value (valueQuantity, valueString, or valueCodeableConcept)"
          end

          errors
        end

        def validate_condition
          errors = []
          errors << "Condition resource must have an id" if blank?(@resource[:id])
          errors << "Condition resource must have a category" if Array(@resource[:category]).empty?
          errors << "Condition resource must have a code" if missing_codeable_concept?(@resource[:code])
          errors << "Condition resource must have a subject" if @resource[:subject].nil? || blank?(@resource.dig(:subject, :reference))
          errors
        end

        def validate_allergy_intolerance
          errors = []
          errors << "AllergyIntolerance resource must have an id" if blank?(@resource[:id])
          errors << "AllergyIntolerance resource must have a code" if missing_codeable_concept?(@resource[:code])
          errors << "AllergyIntolerance resource must have a patient" if @resource[:patient].nil? || blank?(@resource.dig(:patient, :reference))
          errors
        end

        # A usable CodeableConcept needs at least one coding or a text.
        def missing_codeable_concept?(concept)
          concept.nil? || (Array(concept[:coding]).empty? && blank?(concept[:text]))
        end

        def blood_pressure?
          profile = Array(@resource.dig(:meta, :profile)).first.to_s
          profile == US_CORE_BLOOD_PRESSURE
        end

        def validate_blood_pressure_components(errors)
          components = Array(@resource[:component])
          codes = components.map { |c| c.dig(:code, :coding, 0, :code) }

          unless codes.include?(Observation::VITAL_SIGNS_CODES[:systolic])
            errors << "Blood pressure Observation must include a systolic component"
          end

          unless codes.include?(Observation::VITAL_SIGNS_CODES[:diastolic])
            errors << "Blood pressure Observation must include a diastolic component"
          end
        end

        def find_extension(extensions, url)
          extensions.find { |e| e[:url].to_s == url }
        end

        def blank?(value)
          value.nil? || value.to_s.strip.empty?
        end
      end
    end
  end
end
