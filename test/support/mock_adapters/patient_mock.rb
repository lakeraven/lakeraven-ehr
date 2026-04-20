# frozen_string_literal: true

# Patient seed data and CRUD for MockGatewayAdapter.
module MockAdapters
  module PatientMock
    def seed_patients
      register_new_patient(dfn: 1, name: "Anderson,Alice", ssn: "111-11-1111", dob: Date.parse("1980-05-15"), sex: "F", race: "AMERICAN INDIAN",
                           first_name: "Alice", last_name: "Anderson", born_on: Date.parse("1980-05-15"),
                           tribal_affiliation: "Alaska Native - Anchorage (ANLC)", tribal_enrollment_number: "ANLC-12345",
                           service_area: "Anchorage", coverage_type: "IHS",
                           address_line1: "123 Main St", city: "Anchorage", state: "AK", zip_code: "99501", phone: "907-555-1234")
      register_new_patient(dfn: 2, name: "MOUSE,MICKEY M", ssn: "000009999", dob: Date.parse("2010-02-14"), sex: "M", race: "AMERICAN INDIAN",
                           first_name: "Mickey", last_name: "Mouse", born_on: Date.parse("2010-02-14"),
                           tribal_affiliation: "Navajo Nation", tribal_enrollment_number: "NN-67890",
                           service_area: "Arizona", coverage_type: "IHS/Medicaid",
                           address_line1: "456 Disney Ave", city: "Orlando", state: "FL", zip_code: "32801", phone: "555-5678")
      register_new_patient(dfn: 3, name: "DOE,JANE", ssn: "555667777", dob: Date.parse("1990-12-25"), sex: "F", race: "AMERICAN INDIAN",
                           first_name: "Jane", last_name: "Doe", born_on: Date.parse("1990-12-25"),
                           tribal_affiliation: "Choctaw Nation of Oklahoma", tribal_enrollment_number: "CNO-24680",
                           service_area: "Oklahoma", coverage_type: "IHS")
      register_new_patient(dfn: 4, name: "FHIR,TEST", ssn: "999887777", dob: Date.parse("1980-03-15"), sex: "F", race: "AMERICAN INDIAN",
                           first_name: "Test", last_name: "FHIR", born_on: Date.parse("1980-03-15"),
                           tribal_affiliation: "Oglala Sioux Tribe", tribal_enrollment_number: "OST-13579",
                           service_area: "South Dakota", coverage_type: "IHS/Medicare",
                           address_line1: "789 FHIR Blvd", city: "Healthcare", state: "CA", zip_code: "94102", phone: "555-FHIR")
      register_new_patient(dfn: 5, name: "JOHNSON,ROBERT M", ssn: "123456789", dob: Date.parse("1965-03-15"), sex: "M", race: "AMERICAN INDIAN",
                           first_name: "Robert", last_name: "Johnson", born_on: Date.parse("1965-03-15"),
                           tribal_affiliation: "Eastern Band of Cherokee Indians", tribal_enrollment_number: "EBCI-98765",
                           service_area: "North Carolina", coverage_type: "IHS/Medicare",
                           address_line1: "456 Oak Street", city: "Springfield", state: "IL", zip_code: "62701", phone: "555-0123")
    end

    def register_new_patient(patient_data)
      patient_data = patient_data.to_h if patient_data.respond_to?(:to_h)

      @mutex.synchronize do
        new_dfn = patient_data[:dfn] || begin
          all_dfns = stored_patients.keys.select { |k| k >= 10000 }
          all_dfns.any? ? all_dfns.max + 1 : 10000
        end

        stored_patients[new_dfn] = patient_data.dup.merge(dfn: new_dfn)
        { success: true, dfn: new_dfn }
      end
    end

    def update_patient(dfn, changes)
      @mutex.synchronize do
        if stored_patients[dfn]
          stored_patients[dfn].merge!(changes)
          { success: true }
        else
          { success: false, error: "Patient not found" }
        end
      end
    end
  end
end
