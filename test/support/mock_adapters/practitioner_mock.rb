# frozen_string_literal: true

# Practitioner seed data and CRUD for MockGatewayAdapter.
module MockAdapters
  module PractitionerMock
    def seed_practitioners
      create_practitioner(practitioner_ien: 50, provider_ien: 50, name: "PHYSICIAN,EMERGENCY", title: "MD",
                         service_section: "EMERGENCY", service: "Emergency Medicine", specialty: "EMERGENCY MEDICINE",
                         provider_class: "Emergency", npi: "9876543210", dea_number: "EM1234567", phone: "555-EMR1")
      create_practitioner(practitioner_ien: 101, provider_ien: 101, name: "PHYSICIAN,PRIMARY", title: "MD",
                         service_section: "INTERNAL MEDICINE", service: "Family Medicine", specialty: "INTERNAL MEDICINE",
                         provider_class: "Primary Care", npi: "1234567890", dea_number: "AB1234567", phone: "555-PCP1")
      create_practitioner(practitioner_ien: 102, provider_ien: 102, name: "NURSE,HEAD", title: "RN",
                         service_section: "NURSING", service: "Nursing", specialty: "NURSING",
                         provider_class: "Nursing", npi: nil, dea_number: nil, phone: "555-NUR1")
      create_practitioner(practitioner_ien: 202, provider_ien: 202, name: "CARDIOLOGIST,SPECIALIST", title: "MD",
                         service_section: "CARDIOLOGY", service: "Cardiology", specialty: "CARDIOLOGY",
                         provider_class: "Specialist", npi: "2345678901", dea_number: "BC2345678", phone: "555-CARD")
    end

    def create_practitioner(practitioner_data)
      practitioner_data = practitioner_data.to_h if practitioner_data.respond_to?(:to_h)

      @mutex.synchronize do
        new_ien = practitioner_data[:practitioner_ien] || begin
          all_iens = stored_practitioners.keys.select { |k| k >= 10000 }
          all_iens.any? ? all_iens.max + 1 : 10000
        end

        stored_practitioners[new_ien] = practitioner_data.dup.merge(practitioner_ien: new_ien, provider_ien: new_ien)
        { success: true, practitioner_ien: new_ien }
      end
    end
  end
end
