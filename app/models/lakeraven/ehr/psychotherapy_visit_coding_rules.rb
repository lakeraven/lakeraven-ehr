# frozen_string_literal: true

module Lakeraven
  module EHR
    # CPT selection for a behavioral-health visit, from documented face-to-face
    # minutes. Pure: no I/O, no persistence, no descriptor prose.
    #
    # Psychiatric diagnostic evaluation (90791) has no time requirement;
    # a negative duration is still refused.
    # Individual psychotherapy maps to the CMS minute bands:
    #   16–37 → 90832, 38–52 → 90834, 53+ → 90837.
    # Under 16 minutes is documented but not reportable. Missing or
    # non-positive duration never yields a code.
    #
    # Family (90846/90847) and group (90853) stay out of scope until those
    # encounter kinds exist. A clinician may select a code inside the band
    # the minutes support; a selection outside that band is not reportable.
    class PsychotherapyVisitCodingRules
      ENCOUNTER_KIND_PSYCHIATRIC_DIAGNOSTIC_EVALUATION = "psychiatric_diagnostic_evaluation"
      ENCOUNTER_KIND_INDIVIDUAL_PSYCHOTHERAPY = "individual_psychotherapy"

      EVAL_CPT = "90791"
      # Numeric codes only. Descriptor text belongs to LicensedCptContent.
      ALLOWED_CPT_CODES = %w[90791 90832 90834 90837].freeze
      INDIVIDUAL_CPT_CODES = %w[90832 90834 90837].freeze

      # Inclusive ranges. 90837 has no upper bound.
      TIME_BANDS = [
        { code: "90832", min: 16, max: 37 }.freeze,
        { code: "90834", min: 38, max: 52 }.freeze,
        { code: "90837", min: 53, max: nil }.freeze
      ].freeze

      # A row may exist for these and still be refused at finalization.
      # Every other block is a validation failure: the row must not be stored.
      STORABLE_UNRESOLVED = %i[below_minimum_duration selection_inconsistent_with_duration].freeze
      HARD_BLOCKS = %i[
        missing_duration
        invalid_duration
        disallowed_cpt_code
        cpt_code_incompatible_with_encounter_kind
        unknown_encounter_kind
      ].freeze

      Proposal = Struct.new(:cpt_code, :reportable, :blocking_reason, :duration_minutes, keyword_init: true) do
        def reportable? = !!reportable
      end

      def self.default_cpt_code_for_new_episode = EVAL_CPT

      def self.proposal(encounter_kind:, duration_minutes:, selected_cpt_code: nil)
        new(encounter_kind, duration_minutes, selected_cpt_code).proposal
      end

      def initialize(encounter_kind, duration_minutes, selected_cpt_code)
        @encounter_kind = encounter_kind
        @duration_minutes = duration_minutes
        @selected_cpt_code = blank_to_nil(selected_cpt_code)
      end

      def proposal
        return evaluation_proposal if evaluation?
        return individual_proposal if individual?

        unreportable(:unknown_encounter_kind)
      end

      private

      def evaluation?
        @encounter_kind == ENCOUNTER_KIND_PSYCHIATRIC_DIAGNOSTIC_EVALUATION
      end

      def individual?
        @encounter_kind == ENCOUNTER_KIND_INDIVIDUAL_PSYCHOTHERAPY
      end

      def evaluation_proposal
        return unreportable(:invalid_duration) if negative_duration?
        return reportable(EVAL_CPT) if @selected_cpt_code.nil?
        return unreportable(:disallowed_cpt_code) unless allowed?(@selected_cpt_code)
        return unreportable(:cpt_code_incompatible_with_encounter_kind) unless @selected_cpt_code == EVAL_CPT

        reportable(EVAL_CPT)
      end

      def individual_proposal
        return unreportable(:missing_duration) if @duration_minutes.nil?

        minutes = integer_minutes
        return unreportable(:invalid_duration) if minutes.nil? || !minutes.positive?
        return selection_proposal(minutes) if @selected_cpt_code

        derived = band_code(minutes)
        return unreportable(:below_minimum_duration) if derived.nil?

        reportable(derived)
      end

      def selection_proposal(minutes)
        return unreportable(:disallowed_cpt_code) unless allowed?(@selected_cpt_code)
        return unreportable(:cpt_code_incompatible_with_encounter_kind) unless individual_code?(@selected_cpt_code)

        derived = band_code(minutes)
        return unreportable(:below_minimum_duration) if derived.nil?
        return unreportable(:selection_inconsistent_with_duration) if @selected_cpt_code != derived

        reportable(@selected_cpt_code)
      end

      def band_code(minutes)
        TIME_BANDS.find { |band| covers?(band, minutes) }&.fetch(:code)
      end

      def covers?(band, minutes)
        return false if minutes < band[:min]

        band[:max].nil? || minutes <= band[:max]
      end

      def allowed?(code) = ALLOWED_CPT_CODES.include?(code)

      def individual_code?(code) = INDIVIDUAL_CPT_CODES.include?(code)

      def integer_minutes
        @duration_minutes.is_a?(Integer) ? @duration_minutes : nil
      end

      def negative_duration?
        minutes = integer_minutes
        !minutes.nil? && minutes.negative?
      end

      def blank_to_nil(value)
        return nil if value.nil?

        text = value.to_s.strip
        text.empty? ? nil : text
      end

      def reportable(code)
        Proposal.new(cpt_code: code, reportable: true, blocking_reason: nil, duration_minutes: @duration_minutes)
      end

      def unreportable(reason)
        Proposal.new(cpt_code: nil, reportable: false, blocking_reason: reason, duration_minutes: @duration_minutes)
      end
    end
  end
end
