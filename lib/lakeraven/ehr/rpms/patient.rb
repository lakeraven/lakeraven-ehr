# frozen_string_literal: true

module Lakeraven
  module EHR
    module Rpms
      class Patient < Repository
        def find(dfn)
          return validation_failure("DFN is required") if dfn.blank?

          execute(PatientGateway, :find, dfn).and_then do |patient|
            if patient.nil?
              Integrations::Result.failure(
                Integrations::Error.new(code: :not_found, message: "Patient not found for DFN: #{dfn}")
              )
            else
              Integrations::Result.success(patient)
            end
          end
        end

        def search(name_pattern)
          execute(PatientGateway, :search, name_pattern)
        end

        def find_by_ssn(ssn)
          return validation_failure("SSN is required") if ssn.blank?

          execute(PatientGateway, :find_by_ssn, ssn)
        end

        # Clinical data

        def allergies(dfn)
          return validation_failure("DFN is required") if dfn.blank?

          execute(PatientGateway, :allergies, dfn)
        end

        def problem_list(dfn)
          return validation_failure("DFN is required") if dfn.blank?

          execute(PatientGateway, :problem_list, dfn)
        end

        def vitals(dfn)
          return validation_failure("DFN is required") if dfn.blank?

          execute(PatientGateway, :vitals, dfn)
        end

        def appointments(dfn)
          return validation_failure("DFN is required") if dfn.blank?

          execute(PatientGateway, :appointments, dfn)
        end

        # Status checks

        def deceased?(dfn)
          return validation_failure("DFN is required") if dfn.blank?

          execute(PatientGateway, :deceased?, dfn)
        end

        def sensitive?(dfn)
          return validation_failure("DFN is required") if dfn.blank?

          execute(PatientGateway, :sensitive?, dfn)
        end

        # Tribal enrollment

        def tribal_enrollment(dfn)
          return validation_failure("DFN is required") if dfn.blank?

          execute(PatientGateway, :tribal_enrollment, dfn)
        end

        def validate_tribal_enrollment(enrollment_number)
          return validation_failure("Enrollment number is required") if enrollment_number.blank?

          execute(PatientGateway, :validate_tribal_enrollment, enrollment_number)
        end

        def tribe_info(tribe_identifier)
          return validation_failure("Tribe identifier is required") if tribe_identifier.blank?

          execute(PatientGateway, :tribe_info, tribe_identifier)
        end

        def enrollment_eligibility(dfn)
          return validation_failure("DFN is required") if dfn.blank?

          execute(PatientGateway, :enrollment_eligibility, dfn)
        end

        def service_unit(dfn)
          return validation_failure("DFN is required") if dfn.blank?

          execute(PatientGateway, :service_unit, dfn)
        end

        # Registration & update

        def register(patient_data)
          execute(PatientGateway, :register, patient_data)
        end

        def update_demographics(dfn, changes)
          return validation_failure("DFN is required") if dfn.blank?

          execute(PatientGateway, :update_demographics, dfn, changes)
        end

        def create_encounter(encounter_data)
          return validation_failure("Encounter data is required") if encounter_data.blank?
          return validation_failure("DFN is required") if encounter_data[:dfn].blank?

          execute(PatientGateway, :create_encounter, encounter_data)
        end

        # AGG section-based editing

        def get_section(dfn, section)
          return validation_failure("DFN is required") if dfn.blank?
          return validation_failure("Section is required") if section.blank?

          execute(PatientGateway, :get_section, dfn, section)
        end

        def save_section(dfn, section, data)
          return validation_failure("DFN is required") if dfn.blank?
          return validation_failure("Section is required") if section.blank?

          execute(PatientGateway, :save_section, dfn, section, data)
        end

        private

        def validation_failure(message)
          Integrations::Result.failure(
            Integrations::Error.new(code: :validation_failed, message: message)
          )
        end
      end
    end
  end
end
