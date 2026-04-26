# frozen_string_literal: true

module Lakeraven
  module EHR
    # ReportableConditionService -- Detect reportable conditions for eCR
    #
    # ONC 170.315(f)(5) -- Electronic Case Reporting
    #
    # Evaluates patient conditions against the reportable conditions list
    # to determine if an eICR should be generated.
    #
    # Trigger matching uses ICD-10-CM prefix matching: a trigger code of "A15"
    # matches A15.0, A15.1, etc.
    #
    # Ported from rpms_redux ReportableConditionService.
    class ReportableConditionService
      REPORTABLE_CONDITIONS_PATH = Engine.root.join("db/data/reportable_conditions.yml")

      class << self
        # Load all reportable conditions from YAML
        def all_conditions
          @conditions ||= load_conditions
        end

        # Evaluate a condition for reportability
        # @param condition [Condition] Patient condition to evaluate
        # @return [Hash] { reportable:, code:, display:, trigger_source:, jurisdiction:, reporting_timeframe: }
        def evaluate(condition)
          return not_reportable(condition) if condition.code.blank?

          match = find_match(condition.code)
          if match
            {
              reportable: true,
              code: condition.code,
              display: condition.display,
              matched_trigger: match[:code],
              trigger_source: "NYS Reportable Conditions List (10 NYCRR 2.10)",
              jurisdiction: match[:jurisdiction] || "NYS",
              category: match[:category],
              reporting_timeframe: match[:reporting_timeframe]
            }
          else
            not_reportable(condition)
          end
        end

        # Reload conditions (for testing)
        def reload!
          @conditions = nil
        end

        private

        def load_conditions
          return [] unless File.exist?(REPORTABLE_CONDITIONS_PATH)

          Array(YAML.safe_load_file(REPORTABLE_CONDITIONS_PATH, permitted_classes: [])).map do |entry|
            entry.symbolize_keys
          end
        end

        def find_match(code)
          all_conditions.find do |trigger|
            trigger_code = trigger[:code]
            code == trigger_code || code.start_with?(trigger_code)
          end
        end

        def not_reportable(condition)
          { reportable: false, code: condition&.code, display: condition&.display }
        end
      end
    end
  end
end
