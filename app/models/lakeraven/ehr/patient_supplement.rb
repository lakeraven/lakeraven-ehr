# frozen_string_literal: true

module Lakeraven
  module EHR
    # AR-persisted supplement for Patient fields that the mapped RPMS RPC
    # surface doesn't return. Keyed by patient_dfn. Holds SOGI (USCDI v3)
    # and phone (ORWPT SELECT / ORWPT ID INFO carry no telecom; the
    # BHDPTRPC demographics family is future work — until then a deployment
    # can supplement the contact number here and it serializes into
    # Patient.telecom).
    class PatientSupplement < ApplicationRecord
      self.table_name = "lakeraven_ehr_patient_supplements"

      validates :patient_dfn, presence: true, uniqueness: true

      def self.for_patient(dfn)
        find_by(patient_dfn: dfn)
      end
    end
  end
end
