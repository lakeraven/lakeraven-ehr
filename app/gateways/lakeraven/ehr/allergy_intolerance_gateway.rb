# frozen_string_literal: true

require "rpms_rpc/api/allergy"

module Lakeraven
  module EHR
    class AllergyIntoleranceGateway
      # Holds the assessment only while a caller has asked to pair it with
      # the rows for_patient returns. Outside that window nothing is stored:
      # the hash's allergy list is PHI and must not sit on the thread.
      ASSESSMENT_CAPTURE = :lakeraven_orqqal_assessment_capture
      # A DUZ the backend will accept: no sign, no whitespace, no leading zero.
      CANONICAL_DUZ = /\A[1-9]\d*\z/
      # A backend error symbol is safe to keep. Free text is not: it can
      # carry the allergen, a comment, or the broker's own message.
      SAFE_ERROR = /\A[a-z][a-z0-9_]*\z/
      private_constant :ASSESSMENT_CAPTURE, :CANONICAL_DUZ, :SAFE_ERROR

      def self.begin_assessment_capture!
        Thread.current[ASSESSMENT_CAPTURE] = { mark: nil }
      end

      def self.end_assessment_capture!
        Thread.current[ASSESSMENT_CAPTURE] = nil
      end

      # Allergy rows only. NKA, not-assessed, and an empty reply are all [].
      # While a capture is open, the array is the one {assessment} just
      # returned, so the caller can tell those three apart without a second
      # ORQQAL round-trip.
      def self.for_patient(dfn)
        result = assessment(dfn)
        remember_assessment(result)
        result[:allergies]
      end

      # { assessed:, nka:, allergies: } from ORQQAL LIST. Sibling of
      # for_patient so the record-array shape stays what FHIR search expects.
      def self.assessment(dfn)
        RpmsRpc::Allergy.assessment(dfn.to_s)
      end

      # Record one allergy. The originator is the clinician's DUZ: any
      # originator in attrs, string or symbol key, is discarded before the
      # call. A DUZ that is not a positive canonical integer never reaches
      # the backend. Success is only a Hash whose :success is exactly true.
      # Every other reply, and any error the call raises, is a failure
      # result. The exception is not re-raised, and the backend's message
      # text is not kept or logged.
      def self.add(dfn, attrs, clinician_duz: nil)
        duz = canonical_clinician_duz(clinician_duz)
        return failure(:clinician_required) unless duz

        call_allergy(:save) do
          RpmsRpc::Allergy.save(dfn.to_s, allergy_payload(attrs, duz))
        end
      end

      def self.record_no_known_allergies(dfn)
        call_allergy(:no_known_allergies) do
          RpmsRpc::Allergy.no_known_allergies(dfn.to_s)
        end
      end

      # The assessment whose allergy array is `rows`, or nil when these rows
      # came from somewhere else (a stubbed for_patient). Object identity,
      # not contents: two empty lists are not the same assessment.
      def self.take_assessment(rows)
        mark = current_mark
        clear_mark
        return unless mark && mark[:rows].equal?(rows)

        { assessed: mark[:assessed], nka: mark[:nka] }
      end

      def self.remember_assessment(result)
        capture = Thread.current[ASSESSMENT_CAPTURE]
        return unless capture.is_a?(Hash)

        capture[:mark] = {
          assessed: result[:assessed] == true,
          nka: result[:nka] == true,
          rows: result[:allergies]
        }
      end
      private_class_method :remember_assessment

      def self.current_mark
        capture = Thread.current[ASSESSMENT_CAPTURE]
        capture[:mark] if capture.is_a?(Hash)
      end
      private_class_method :current_mark

      def self.clear_mark
        capture = Thread.current[ASSESSMENT_CAPTURE]
        capture[:mark] = nil if capture.is_a?(Hash)
      end
      private_class_method :clear_mark

      def self.canonical_clinician_duz(value)
        case value
        when Integer then value.positive? ? value : nil
        when String then value.match?(CANONICAL_DUZ) ? value : nil
        end
      end
      private_class_method :canonical_clinician_duz

      def self.allergy_payload(attrs, duz)
        payload = attrs.is_a?(Hash) ? attrs.deep_dup.deep_symbolize_keys : {}
        payload.delete(:originator)
        payload[:originator] = duz
        payload
      end
      private_class_method :allergy_payload

      def self.call_allergy(action)
        reply = yield
        return success_result(reply) if success_reply?(reply)

        reason = failure_reason(reply)
        log_allergy_failure(action, reason)
        failure(reason)
      rescue StandardError => error
        log_allergy_exception(action, error)
        failure(:unavailable)
      end
      private_class_method :call_allergy

      def self.success_reply?(reply)
        reply.is_a?(Hash) && reply[:success] == true
      end
      private_class_method :success_reply?

      def self.success_result(reply)
        { success: true, note_ien: reply[:note_ien] }
      end
      private_class_method :success_result

      def self.failure_reason(reply)
        error = reply_error(reply)
        return error if error.is_a?(Symbol) && error.name.match?(SAFE_ERROR)

        :rejected
      end
      private_class_method :failure_reason

      def self.reply_error(reply)
        return unless reply.is_a?(Hash)

        reply[:error] || reply["error"]
      end
      private_class_method :reply_error

      def self.failure(reason)
        { success: false, error: reason }
      end
      private_class_method :failure

      def self.log_allergy_failure(action, reason)
        Rails.logger.warn("[allergy] #{action} failed: #{reason}")
      end
      private_class_method :log_allergy_failure

      def self.log_allergy_exception(action, error)
        Rails.logger.warn("[allergy] #{action} failed: #{error.class}")
      end
      private_class_method :log_allergy_exception
    end
  end
end
