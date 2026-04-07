# frozen_string_literal: true

module Lakeraven
  module EHR
    module FHIR
      # Builds a FHIR R4 OperationOutcome resource as a Ruby Hash.
      #
      # Used by controllers to render error responses (404 not-found,
      # 400 required, 403 forbidden) in the FHIR-conventional way
      # rather than as plain Rails JSON errors. The shape is small
      # enough that this could live in the controller, but extracting
      # it makes the controllers easier to read and the failure modes
      # easier to test in isolation.
      class OperationOutcome
        # https://hl7.org/fhir/R4/valueset-issue-severity.html
        VALID_SEVERITIES = %w[fatal error warning information].freeze

        def self.call(severity:, code:, diagnostics: nil)
          unless VALID_SEVERITIES.include?(severity)
            raise ArgumentError, "invalid OperationOutcome severity: #{severity.inspect} (expected one of #{VALID_SEVERITIES})"
          end

          issue = { severity: severity, code: code }
          issue[:diagnostics] = diagnostics if diagnostics

          {
            resourceType: "OperationOutcome",
            issue: [ issue ]
          }
        end
      end
    end
  end
end
