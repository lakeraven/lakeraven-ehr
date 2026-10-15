# frozen_string_literal: true

module Lakeraven
  module EHR
    # Finishes a behavioral-health encounter only when its visit coding is
    # resolved. The refusal lives here, on the encounter the rest of the
    # chart already uses — not in a view, and not on a second encounter type.
    class BehavioralHealthVisitFinalizationService
      Result = Struct.new(:success, :error, keyword_init: true) do
        def success? = !!success
      end

      def initialize(encounter:, visit_coding:)
        @encounter = encounter
        @visit_coding = visit_coding
      end

      def finalize
        return failure(:coding_missing) if @visit_coding.nil?
        return failure(:coding_unresolved) unless @visit_coding.resolved?
        return failure(:coding_unresolved) unless @encounter.close

        Result.new(success: true)
      end

      private

      def failure(reason)
        Result.new(success: false, error: reason)
      end
    end
  end
end
