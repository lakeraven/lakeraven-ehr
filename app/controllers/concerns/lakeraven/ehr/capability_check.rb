# frozen_string_literal: true

module Lakeraven
  module EHR
    # Whether the signed-in user holds the named capability (Capabilities,
    # ADR 0010), from the keys RPMS reported at sign-on. Views ask the same
    # question, so a control a user sees is one the server allows.
    #
    # One definition for both browser bases: WebController, and
    # ChartsController, which inherits ActionController::Base on its own so it
    # can carry the FHIR controllers' protections.
    module CapabilityCheck
      extend ActiveSupport::Concern

      included do
        helper_method :capability?
      end

      private

      def capability?(name)
        Capabilities.allows?(current_security_keys, name)
      end

      def current_security_keys
        Array(session[:security_keys])
      end
    end
  end
end
