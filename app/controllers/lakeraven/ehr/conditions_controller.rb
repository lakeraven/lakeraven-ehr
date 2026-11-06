# frozen_string_literal: true

module Lakeraven
  module EHR
    class ConditionsController < ApplicationController
      include PatientScopedRead

      private

      def patient_resources(dfn)
        problems = Condition.for_patient(dfn).map { |row| Condition.from_rpms_row(row, patient_dfn: dfn) }
        (problems + visit_diagnoses(dfn)).map(&:to_fhir)
      end

      def visit_diagnoses(dfn)
        rows = ConditionGateway.visit_diagnoses(dfn)
        return [] if rows.empty?

        listed = EncounterGateway.visits(dfn).map { |visit| visit[:visit_ien] }
        rows.map { |row| Condition.from_pov_row(row, patient_dfn: dfn, listed_visits: listed) }
      end
    end
  end
end
