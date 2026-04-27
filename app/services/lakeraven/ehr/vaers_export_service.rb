# frozen_string_literal: true

module Lakeraven
  module EHR
    # VaersExportService -- stateless transformer: patient + immunization -> VaersReport/CSV
    #
    # ONC 170.315(f)(1) -- VAERS adverse event reporting
    #
    # No database records created. VaersReport is ActiveModel (no table).
    # Patient demographics from Patient model, vaccine data from Immunization model.
    # Adverse event description is clinician-provided (VAERS is clinician-initiated).
    class VaersExportService
      class << self
        def generate(patient_dfn:, immunization_ien:, reporter_name:, adverse_event_description:, onset_date: nil)
          patient = Patient.find_by_dfn(patient_dfn)
          immunization = Immunization.find_by_ien(immunization_ien)

          build_report(
            patient: patient,
            immunization: immunization,
            adverse_event_description: adverse_event_description,
            onset_date: onset_date,
            reporter_name: reporter_name
          )
        end

        def generate_csv(patient_dfn:, immunization_ien:, reporter_name:, adverse_event_description:, onset_date: nil)
          report = generate(
            patient_dfn: patient_dfn,
            immunization_ien: immunization_ien,
            reporter_name: reporter_name,
            adverse_event_description: adverse_event_description,
            onset_date: onset_date
          )
          report.to_csv
        end

        private

        def build_report(patient:, immunization:, adverse_event_description:, onset_date:, reporter_name:)
          VaersReport.new(
            patient_name: patient&.name || patient&.full_name,
            patient_dob: patient&.dob || patient&.birth_date,
            patient_sex: patient&.sex,
            vaccine_name: immunization&.vaccine_display,
            vaccine_date: immunization&.occurrence_datetime,
            adverse_event: adverse_event_description,
            onset_date: onset_date
          )
        end
      end
    end
  end
end
