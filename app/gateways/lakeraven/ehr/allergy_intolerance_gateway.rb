# frozen_string_literal: true

require "rpms_rpc/api/allergy"

module Lakeraven
  module EHR
    class AllergyIntoleranceGateway
      # Holds the assessment only while a caller has asked to pair it with
      # the rows for_patient returns. Outside that window nothing is stored:
      # the hash's allergy list is PHI and must not sit on the thread.
      ASSESSMENT_CAPTURE = :lakeraven_orqqal_assessment_capture
      private_constant :ASSESSMENT_CAPTURE

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
    end
  end
end
