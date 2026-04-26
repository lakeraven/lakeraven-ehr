# frozen_string_literal: true

module Lakeraven
  module EHR
    # ReportableLabService -- Detect reportable lab tests for ELR
    #
    # ONC 170.315(f)(3) -- Electronic Laboratory Reporting
    #
    # Evaluates lab results (Observations) against the reportable lab tests list
    # to determine if an HL7 ORU message should be generated.
    #
    # Trigger matching uses exact LOINC code comparison.
    #
    # Ported from rpms_redux ReportableLabService.
    class ReportableLabService
      REPORTABLE_LAB_TESTS_PATH = Engine.root.join("db/data/reportable_lab_tests.yml")

      class << self
        def all_tests
          @tests ||= load_tests
        end

        # Evaluate a lab observation for reportability
        # @param observation [Observation] Lab observation to evaluate
        # @return [Hash] { reportable:, loinc:, display:, trigger_source:, jurisdiction:, reporting_timeframe: }
        def evaluate(observation)
          return not_reportable(observation) if observation.code.blank?

          match = find_match(observation.code)
          if match
            {
              reportable: true,
              loinc: observation.code,
              display: observation.display,
              matched_trigger: match[:loinc],
              trigger_source: "NYS Reportable Lab Tests List (10 NYCRR 2.10)",
              jurisdiction: match[:jurisdiction] || "NYS",
              category: match[:category],
              organism_snomed: match[:organism_snomed],
              organism_display: match[:organism_display],
              reporting_timeframe: match[:reporting_timeframe]
            }
          else
            not_reportable(observation)
          end
        end

        def reload!
          @tests = nil
        end

        private

        def load_tests
          return [] unless File.exist?(REPORTABLE_LAB_TESTS_PATH)

          Array(YAML.safe_load_file(REPORTABLE_LAB_TESTS_PATH, permitted_classes: [])).map do |entry|
            entry.symbolize_keys
          end
        end

        def find_match(loinc_code)
          all_tests.find { |trigger| trigger[:loinc] == loinc_code }
        end

        def not_reportable(observation)
          { reportable: false, loinc: observation&.code, display: observation&.display }
        end
      end
    end
  end
end
