# frozen_string_literal: true

module Lakeraven
  module EHR
    # SmartAuthentication for the HTML clinician surfaces.
    #
    # Same credential, same checks, same failures as the FHIR controllers —
    # only the representation of a refusal differs: a browser gets plain text
    # rather than a FHIR OperationOutcome. ChartsController does the same thing
    # for the HTML chart.
    #
    # Declared as an ActiveSupport::Concern dependency so SmartAuthentication
    # is mixed in FIRST and these overrides take precedence.
    module BrowserSmartAuthentication
      extend ActiveSupport::Concern
      include SmartAuthentication

      private

      def render_unauthorized(message = "Unauthorized")
        render plain: "Unauthorized: #{message}", status: :unauthorized
      end

      def render_forbidden(message = "Forbidden")
        render plain: "Forbidden: #{message}", status: :forbidden
      end
    end
  end
end
