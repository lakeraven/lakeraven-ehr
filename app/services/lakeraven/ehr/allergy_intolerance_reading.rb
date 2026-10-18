# frozen_string_literal: true

module Lakeraven
  module EHR
    # The merged allergy list plus the facts an Array cannot carry.
    #
    # FHIR search still wants the rows. Display cannot: ORQQAL's record
    # list is [] for assessed-NKA, for "no assessment", and for an
    # indeterminate reply, and a row dropped for ownership — wire or
    # supplemental — leaves the same hole. Those are not "none recorded".
    class AllergyIntoleranceReading < Array
      attr_reader :dropped_count, :assessed, :nka

      def initialize(records = [], dropped_count: 0, assessed: false, nka: false)
        super()
        replace(Array(records))
        @dropped_count = dropped_count.to_i
        @assessed = assessed == true
        @nka = nka == true
      end

      # Assessed NKA, nothing dropped, and nothing left after the merge.
      def verified_absence?
        assessed && nka && dropped_count.zero? && empty?
      end
    end
  end
end
