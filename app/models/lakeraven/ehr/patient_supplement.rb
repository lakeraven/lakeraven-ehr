# frozen_string_literal: true

module Lakeraven
  module EHR
    # AR-persisted supplement for Patient fields that RPMS doesn't store.
    # Keyed by patient_dfn. Currently holds SOGI (USCDI v3).
    class PatientSupplement < ApplicationRecord
      self.table_name = "lakeraven_ehr_patient_supplements"

      validates :patient_dfn, presence: true, uniqueness: true

      def self.for_patient(dfn)
        find_by(patient_dfn: dfn)
      end
    end
  end
end
