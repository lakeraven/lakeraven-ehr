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

      def self.update(dfn, ien, changes)
        if diagnosis_coded?(changes)
          refusal = shared_problem_list_refusal(changes)
          return refusal if refusal
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
