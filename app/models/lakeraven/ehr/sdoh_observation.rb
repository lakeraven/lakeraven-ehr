# frozen_string_literal: true

module Lakeraven
  module EHR
    class SdohObservation
      SOCIAL_HISTORY_CODES = {
        "71802-3" => "Housing status",
        "88122-7" => "Food insecurity",
        "93029-7" => "Financial resource strain",
        "67875-5" => "Employment status"
      }.freeze

      SURVEY_CODES = {
        "93025-5" => "PRAPARE screening",
        "96777-8" => "AHC-HRSN screening"
      }.freeze

      US_CORE_SOCIAL_HISTORY_PROFILE = "http://hl7.org/fhir/us/core/StructureDefinition/us-core-observation-social-history"
      US_CORE_SCREENING_PROFILE = "http://hl7.org/fhir/us/core/StructureDefinition/us-core-observation-screening-assessment"

      def self.category_for(code)
        return "survey" if SURVEY_CODES.key?(code)
        return "social-history" if SOCIAL_HISTORY_CODES.key?(code)

        nil
      end

      def self.profile_for(code)
        case category_for(code)
        when "social-history" then US_CORE_SOCIAL_HISTORY_PROFILE
        when "survey" then US_CORE_SCREENING_PROFILE
        end
      end

      def self.known_code?(code)
        SOCIAL_HISTORY_CODES.key?(code) || SURVEY_CODES.key?(code)
      end
    end
  end
end
