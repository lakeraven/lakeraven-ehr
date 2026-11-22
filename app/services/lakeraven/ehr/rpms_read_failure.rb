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

      # Errors with their own handlers (RpmsUserScope, the audit concern).
      # A read seam re-raises these unchanged: they are not a section's
      # failure, and rendering them as one would hide a lost session, a
      # missing configuration or an unrecorded access.
      PASS_THROUGH = [
        ::RpmsRpc::NotConfiguredError,
        Lakeraven::EHR::RpmsSessions::SignInAgain,
        ::RpmsRpc::SessionPool::PoolExhaustedError,
        Lakeraven::EHR::AuditedBroker::UnrecordedAccessError
      ].freeze

      attr_reader :cause, :noun

      # A read that answered, but not with a list (nil, a Hash, a String).
      # That is a failure, never "no data". There is no exception, so no
      # backtrace is invented: the log names the class that came back.
      def self.not_a_list(noun:, returned:, subject: nil)
        new(nil, noun: noun, subject: subject, returned: returned)
      end

      # Anything a read may return as its list: an Array, or an Enumerable
      # that converts to one (an ActiveRecord relation).
      def self.list?(value)
        value.respond_to?(:to_ary) || value.is_a?(ActiveRecord::Relation)
      end

      # noun: the lower-case plural the section is called in prose ("problems").
      # subject: what the diagnostics call the section, when that is not the
      # FHIR resource type ("Immunizations"). returned: the class of a
      # non-list answer (see not_a_list).
      def initialize(error, noun:, subject: nil, returned: nil)
        @cause = classify(error)
        @noun = noun
        @subject = subject
        @error_class = returned || error.class
        @detail = returned ? "returned #{returned}, not a list" : "#{error.class} at #{source_locations(error).join(', ')}"
      end

      def fhir_code = FHIR_CODES.fetch(cause)

      # One log call. A refusal or an RPC the server does not offer is the
      # server answering as configured: WARN, class only. Anything else is a
      # fault, so ERROR, with the class and where it was raised. The message
      # is never logged: it can carry PHI.
      def log(logger, label)
        if cause == FAILED
          logger.error("#{label} failed: #{@detail}")
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

      # OperationOutcome diagnostics naming the FHIR resource type, or the
      # subject when one was given (a section that spans resource types).
      def diagnostics(resource_type)
        name = @subject || resource_type
        case cause
        when REFUSED then "Access to #{name} is not permitted for this user."
        when NOT_OFFERED then "Access to #{name} is not offered on this RPMS server."
        else "#{name} could not be loaded."
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
        return FAILED if error.nil?

        case error
        when ::RpmsRpc::Client::RpcRefusedError then REFUSED
        when ::RpmsRpc::Client::RpcNotAvailableError then NOT_OFFERED
        else FAILED
        end
      end
    end
  end
end
