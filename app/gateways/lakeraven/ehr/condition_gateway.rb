# frozen_string_literal: true

require "rpms_rpc/api/problem"

module Lakeraven
  module EHR
    # Engine-side gateway over RpmsRpc::Problem. The engine vocabulary is
    # "Condition" (matches FHIR / app/models/lakeraven/ehr/condition.rb); the
    # underlying RPC module is "Problem" (IPL terminology).
    #
    # add, and update when the change carries a diagnosis code, refuse a
    # payload Icd10CmSubstanceUseRange calls :sud or :unclassified. The
    # shared problem file has no per-record sensitivity flag, so a write
    # there cannot be pulled back. :not_sud still goes to RpmsRpc::Problem.
    # A refusal is not written anywhere else — there is no Part 2 store.
    # An update that carries no code is not re-read against the row already
    # stored; this gateway does not fetch that row.
    class ConditionGateway
      SUD_WRITE_REFUSAL =
        "refused: shared RPMS problem list has no per-record sensitivity flag, " \
        "and there is no Part 2 store to write instead".freeze
      UNCODED_NARRATIVE_REFUSAL =
        "refused: update rewrites clinical text with no diagnosis code, so it " \
        "cannot be classified against ICD-10-CM; send the code with the text".freeze
      # Keys that carry clinical narrative, as opposed to administrative state
      # such as status or onset. A narrative change is what can silently turn a
      # row into a substance-use record.
      NARRATIVE_KEYS = %i[display description narrative text comment].freeze
      UNCLASSIFIED_WRITE_REFUSAL =
        "refused: condition could not be classified against ICD-10-CM F10-F19; " \
        "not written to the shared RPMS problem list".freeze

      def self.for_patient(dfn)
        RpmsRpc::Problem.for_patient(dfn.to_s)
      end

      def self.add(dfn, problem)
        refusal = shared_problem_list_refusal(problem)
        return refusal if refusal

        RpmsRpc::Problem.add(dfn.to_s, problem)
      end

      # An update that rewrites CLINICAL TEXT without a diagnosis code is
      # refused. An administrative-only update is not.
      #
      # A gate seat found that `update(dfn, ien, display: "Opioid use
      # disorder")` reached RpmsRpc::Problem.update unchecked, because the
      # classifier only ran when a code was present. This gateway cannot
      # re-read the stored row, so with no code it cannot classify what the
      # new text says — and absence of a code is not evidence the change is
      # safe to put in a file with no per-record sensitivity flag.
      #
      # Narrow on purpose. A first attempt refused EVERY uncoded update and
      # broke `update(dfn, ien, status: "I")` — marking a problem inactive
      # carries no diagnosis and needs no classification. Over-blocking a
      # legitimate administrative write is its own defect, so only changes
      # carrying clinical narrative are refused. The caller's remedy is to
      # send the diagnosis code alongside the text.
      def self.update(dfn, ien, changes)
        if diagnosis_coded?(changes)
          refusal = shared_problem_list_refusal(changes)
          return refusal if refusal
        elsif clinical_narrative?(changes)
          return UNCODED_NARRATIVE_REFUSAL
        end

        RpmsRpc::Problem.update(dfn.to_s, ien.to_s, changes)
      end

      def self.delete(dfn, ien, reason:)
        RpmsRpc::Problem.delete(dfn.to_s, ien.to_s, reason: reason)
      end

      def self.filter(dfn, scope:)
        RpmsRpc::Problem.filter(dfn.to_s, scope: scope)
      end

      def self.diagnosis_coded?(problem)
        return false unless problem.is_a?(Hash)

        %i[code icd_code].any? { |key| problem.key?(key) || problem.key?(key.to_s) }
      end
      private_class_method :diagnosis_coded?

      def self.clinical_narrative?(changes)
        return false unless changes.is_a?(Hash)

        NARRATIVE_KEYS.any? do |key|
          (changes.key?(key) && changes[key].present?) ||
            (changes.key?(key.to_s) && changes[key.to_s].present?)
        end
      end
      private_class_method :clinical_narrative?

      def self.shared_problem_list_refusal(problem)
        case Icd10CmSubstanceUseRange.classify(problem)
        when :sud
          code = Icd10CmSubstanceUseRange.normalized_code(problem)
          refused_problem("#{code} is in ICD-10-CM F10-F19; #{SUD_WRITE_REFUSAL}")
        when :unclassified
          refused_problem(UNCLASSIFIED_WRITE_REFUSAL)
        end
      end
      private_class_method :shared_problem_list_refusal

      def self.refused_problem(reason)
        { success: false, ien: nil, error: reason }
      end
      private_class_method :refused_problem
    end
  end
end
