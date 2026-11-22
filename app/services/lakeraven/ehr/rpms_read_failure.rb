# frozen_string_literal: true

module Lakeraven
  module EHR
    # Why an RPMS-backed read did not return a list.
    #
    # A refusal, an RPC the server does not offer, and any other raise are not
    # "no data", and each says something different to the person reading the
    # chart. This classifies the exception once; the chart renders the cause
    # from fixed strings. The exception message is never read here: it can
    # carry broker detail and PHI.
    #
    # Both typed errors subclass RpcError, so they are matched before the
    # generic case.
    class RpmsReadFailure
      REFUSED = :refused
      NOT_OFFERED = :not_offered
      FAILED = :failed

      FHIR_CODES = {
        REFUSED => "forbidden",
        NOT_OFFERED => "not-supported",
        FAILED => "exception"
      }.freeze

      attr_reader :cause, :noun, :error_class

      # noun: the lower-case plural the section is called in prose ("problems").
      def initialize(error, noun:)
        @cause = classify(error)
        @noun = noun
        @error_class = error.class
      end

      def fhir_code = FHIR_CODES.fetch(cause)

      def refused? = cause == REFUSED

      # Chart section text.
      def html_message
        case cause
        when REFUSED then "You are not permitted to view #{noun} on this RPMS server."
        when NOT_OFFERED then "#{noun.upcase_first} are not offered on this RPMS server."
        else "#{noun.upcase_first} could not be loaded."
        end
      end

      # OperationOutcome diagnostics naming the FHIR resource type.
      # generic_subject overrides the name in the generic failure text only.
      def diagnostics(resource_type, generic_subject: resource_type)
        case cause
        when REFUSED then "#{resource_type} is not permitted for this user."
        when NOT_OFFERED then "#{resource_type} is not offered on this RPMS server."
        else "#{generic_subject} could not be loaded."
        end
      end

      private

      def classify(error)
        case error
        when ::RpmsRpc::Client::RpcRefusedError then REFUSED
        when ::RpmsRpc::Client::RpcNotAvailableError then NOT_OFFERED
        else FAILED
        end
      end
    end
  end
end
