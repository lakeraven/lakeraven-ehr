# frozen_string_literal: true

module Lakeraven
  module EHR
    class ConditionsController < ApplicationController
      include PatientScopedRead

      private

      def patient_resources(dfn)
        Condition.for_patient(dfn).map { |row| Condition.from_rpms_row(row, patient_dfn: dfn).to_fhir }
      end
    end
  end
end
