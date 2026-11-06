# frozen_string_literal: true

module Lakeraven
  module EHR
    # A SMART scope in plain words, for the approval screen (#839): what the
    # app will be able to do, said the way a clinician would say it.
    #
    #   ScopeDescription.for("user/AllergyIntolerance.rs")
    #   # => "See patients' allergies"
    class ScopeDescription
      # FHIR type => the record it holds, in plain words.
      RECORDS = {
        "AllergyIntolerance" => "allergies",
        "CarePlan" => "care plans",
        "Condition" => "problems and health concerns",
        "Coverage" => "insurance",
        "CoverageEligibilityRequest" => "insurance eligibility checks",
        "DiagnosticReport" => "test reports",
        "Encounter" => "visits",
        "Immunization" => "immunizations",
        "Location" => "clinic locations",
        "Medication" => "medications",
        "MedicationRequest" => "medication orders",
        "Observation" => "vital signs and other results",
        "Organization" => "the clinic's details",
        "Patient" => "names, birth dates and contact details",
        "Practitioner" => "providers' names",
        "Procedure" => "procedures",
        "Provenance" => "who recorded each entry",
        "ServiceRequest" => "referrals"
      }.freeze

      # Types that describe the clinic, not a patient.
      CLINIC_RECORDS = %w[Location Organization Practitioner].freeze

      def self.for(scope) = new(scope).to_s

      def initialize(scope)
        @scope = SmartScope.parse(scope.to_s)
        @raw = scope.to_s
      end

      def to_s
        return @raw unless @scope

        "#{verbs} #{whose}#{record}"
      end

      private

      def verbs
        words = []
        words << "see" if (@scope.permissions & %w[r s]).any?
        words << "add" if @scope.permissions.include?("c")
        words << "change" if @scope.permissions.include?("u")
        words << "remove" if @scope.permissions.include?("d")
        words.to_sentence(two_words_connector: " and ", last_word_connector: " and ").capitalize
      end

      def whose
        return "" if CLINIC_RECORDS.include?(@scope.resource_type)

        @scope.context == "patient" ? "this patient's " : "patients' "
      end

      def record
        return "everything in the record" if @scope.resource_type == "*"

        RECORDS.fetch(@scope.resource_type) { @scope.resource_type }
      end
    end
  end
end
