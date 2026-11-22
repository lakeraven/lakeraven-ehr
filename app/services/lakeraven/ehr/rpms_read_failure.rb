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

      # Frames kept in an ERROR log line: enough to place the raise, few
      # enough that the line stays one line.
      LOCATION_FRAMES = 3

      attr_reader :cause, :noun

      # noun: the lower-case plural the section is called in prose ("problems").
      # subject: what the generic failure text calls the section, when that is
      # not the FHIR resource type ("Immunizations").
      def initialize(error, noun:, subject: nil)
        @cause = classify(error)
        @noun = noun
        @subject = subject
        @error_class = error.class
        @locations = source_locations(error)
      end

      def fhir_code = FHIR_CODES.fetch(cause)

      # One log call. A refusal or an RPC the server does not offer is the
      # server answering as configured: WARN, class only. Anything else is a
      # fault, so ERROR, with the class and where it was raised. The message
      # is never logged: it can carry PHI.
      def log(logger, label)
        if cause == FAILED
          logger.error("#{label} failed: #{@error_class} at #{@locations.join(', ')}")
        else
          logger.warn("#{label} failed: #{@error_class}")
        end
      end

      # Chart section text.
      def html_message
        case cause
        when REFUSED then "You are not permitted to view #{noun} on this RPMS server."
        when NOT_OFFERED then "#{noun.upcase_first} are not offered on this RPMS server."
        else "#{noun.upcase_first} could not be loaded."
        end
      end

      # OperationOutcome diagnostics naming the FHIR resource type. The
      # generic failure text uses the subject, when one was given.
      def diagnostics(resource_type)
        case cause
        when REFUSED then "#{resource_type} is not permitted for this user."
        when NOT_OFFERED then "#{resource_type} is not offered on this RPMS server."
        else "#{@subject || resource_type} could not be loaded."
        end
      end

      private

      # "path:line" for the first frames, engine code before gem and stdlib
      # frames, so the line names where this application went wrong.
      def source_locations(error)
        frames = Array(error.backtrace_locations)
        own = frames.select { |frame| frame.absolute_path.to_s.start_with?(Engine.root.to_s) }
        (own.presence || frames).first(LOCATION_FRAMES).map { |frame| "#{frame.path}:#{frame.lineno}" }
      end

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
