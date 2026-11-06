# frozen_string_literal: true

module Lakeraven
  module EHR
    module FHIR
      # The id of a resource RPMS holds per patient: "<dfn>-<record id>".
      #
      # RPMS reads these records by patient. ORQQPL, ORQQAL and the V files
      # have no read by record alone, so a bare id would leave a read with no
      # patient to ask for, and nothing to bind a patient-scoped token to. The
      # id names the patient, the compartment is checked against that patient,
      # and the record is found in that patient's list, so naming another
      # patient's record under your own DFN finds nothing.
      module PatientScopedId
        FORMAT = /\A(?<dfn>[1-9]\d*)-(?<record>.+)\z/

        def self.build(dfn, record_id)
          "#{dfn}-#{record_id}" if record_id.present?
        end

        def self.patient_dfn(id)
          FORMAT.match(id.to_s)&.[](:dfn)
        end
      end
    end
  end
end
