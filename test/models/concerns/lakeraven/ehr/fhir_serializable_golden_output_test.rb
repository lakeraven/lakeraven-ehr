# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class FHIRSerializableGoldenOutputTest < ActiveSupport::TestCase
      ORGANIZATION_GOLDEN_FHIR = {
        resourceType: "Organization",
        id: "242",
        name: "Golden Spec Organization",
        active: true,
        identifier: [
          { use: "usual", system: "http://ihs.gov/rpms/organization-id", value: "242" },
          { system: "http://hl7.org/fhir/sid/us-npi", value: "9998887770" },
          { use: "official", system: "http://hl7.org/fhir/sid/us-npi", value: "1234567890" },
          { use: "official", system: "urn:oid:2.16.840.1.113883.4.4", value: "12-3456789" }
        ],
        type: [
          {
            coding: [
              {
                system: "http://terminology.hl7.org/CodeSystem/organization-type",
                code: "prov",
                display: "Healthcare Provider"
              }
            ]
          }
        ],
        address: [
          {
            line: [ "100 Spec St" ],
            city: "Specville",
            state: "WA",
            postalCode: "98101",
            country: "US"
          }
        ],
        telecom: [ { system: "phone", value: "555-0242", use: "work" } ],
        partOf: { reference: "Organization/241" }
      }.freeze

      ENCOUNTER_GOLDEN_FHIR = {
        resourceType: "Encounter",
        meta: {
          profile: [ "http://hl7.org/fhir/us/core/StructureDefinition/us-core-encounter" ]
        },
        status: "finished",
        class: {
          system: "http://terminology.hl7.org/CodeSystem/v3-ActCode",
          code: "AMB",
          display: "Ambulatory"
        },
        id: "242",
        period: { start: "2024-06-01T10:00:00Z", end: "2024-06-01T11:00:00Z" },
        type: [ { text: "Encounter for check up", coding: [ { code: "185349003" } ] } ],
        reasonCode: [ { text: "General exam", coding: [ { code: "Z00.00" } ] } ],
        subject: { reference: "Patient/1" },
        participant: [ { individual: { reference: "Practitioner/101" } } ],
        location: [ { location: { reference: "Location/rpms-location-5" } } ],
        serviceProvider: { reference: "Organization/rpms-organization-10" }
      }.freeze

      COVERAGE_GOLDEN_FHIR = {
        resourceType: "Coverage",
        id: "cov-golden-242",
        status: "active",
        beneficiary: { reference: "Patient/1" },
        payor: [ { reference: "Organization/StateMedicaid", display: "State Medicaid" } ],
        period: { start: "2025-01-01", end: "2025-12-31" },
        class: [
          { type: { coding: [ { code: "group" } ] }, value: "GRP242" },
          { type: { coding: [ { code: "plan" } ] }, value: "MCD242", name: "Spec Plan" }
        ]
      }.freeze

      SERVICE_REQUEST_GOLDEN_FHIR = {
        resourceType: "ServiceRequest",
        id: "242",
        identifier: [
          { use: "official", system: "http://ihs.gov/rpms/consult-id", value: "242" },
          {
            use: "usual",
            system: "http://ihs.gov/rpms/service-request-identifier",
            value: "SR-GOLDEN-242"
          }
        ],
        status: "active",
        intent: "order",
        priority: "routine",
        code: {
          coding: [
            {
              system: "http://snomed.info/sct",
              code: "3457005",
              display: "Patient referral"
            }
          ],
          text: "Cardiology consult"
        },
        subject: { reference: "Patient/100" },
        authoredOn: "2024-03-15",
        reasonCode: [ { text: "Chest pain" } ]
      }.freeze

      CONSENT_GOLDEN_FHIR = {
        resourceType: "Consent",
        status: "active",
        patient: { reference: "Patient/1" },
        scope: {
          coding: [
            {
              system: "http://terminology.hl7.org/CodeSystem/consentscope",
              code: "patient-privacy",
              display: "Privacy Consent"
            }
          ]
        },
        category: [
          {
            coding: [
              {
                system: "http://loinc.org",
                code: "59284-0",
                display: "Consent Document"
              }
            ]
          }
        ],
        dateTime: "2024-01-10",
        performer: [ { reference: "Practitioner/rpms-practitioner-101" } ],
        provision: {
          type: "permit",
          actor: [],
          action: [
            {
              coding: [
                {
                  system: "http://terminology.hl7.org/CodeSystem/consentaction",
                  code: "access"
                }
              ]
            }
          ],
          period: { start: "2024-01-01", end: "2025-12-31" }
        },
        id: "consent-golden-242"
      }.freeze

      FHIR_ADOPTION_MODELS = [
        Organization,
        Encounter,
        Coverage,
        ServiceRequest,
        Consent
      ].freeze

      FHIR_ADOPTION_MODELS.each do |model|
        test "#{model.name.demodulize} includes FHIRSerializable" do
          assert(
            model.included_modules.any? { |mod| mod.name == "Lakeraven::EHR::FHIRSerializable" },
            "expected #{model.name} to include Lakeraven::EHR::FHIRSerializable"
          )
        end
      end

      test "Organization to_fhir golden output unchanged for representative synthetic record" do
        org = Organization.new(
          ien: 242,
          name: "Golden Spec Organization",
          org_type: "prov",
          npi: "1234567890",
          tax_id: "12-3456789",
          station_number: "9998887770",
          active: true,
          address: "100 Spec St",
          city: "Specville",
          state: "WA",
          zip_code: "98101",
          phone: "555-0242",
          parent_organization_ien: 241
        )

        assert_equal ORGANIZATION_GOLDEN_FHIR, org.to_fhir
      end

      test "Encounter to_fhir golden output unchanged for representative synthetic record" do
        enc = Encounter.new(
          ien: 242,
          status: "finished",
          class_code: "AMB",
          period_start: Time.utc(2024, 6, 1, 10, 0, 0),
          period_end: Time.utc(2024, 6, 1, 11, 0, 0),
          type_code: "185349003",
          type_display: "Encounter for check up",
          reason_code: "Z00.00",
          reason_display: "General exam",
          patient_identifier: "1",
          practitioner_identifier: "101",
          location_ien: 5,
          service_provider_organization_ien: 10
        )

        assert_equal ENCOUNTER_GOLDEN_FHIR, enc.to_fhir
      end

      test "Coverage to_fhir golden output unchanged for representative synthetic record" do
        cov = Coverage.new(
          id: "cov-golden-242",
          patient_dfn: "1",
          coverage_type: "medicaid",
          status: "active",
          payor_name: "State Medicaid",
          subscriber_id: "MCD242",
          group_id: "GRP242",
          plan_name: "Spec Plan",
          start_date: Date.new(2025, 1, 1),
          end_date: Date.new(2025, 12, 31)
        )

        assert_equal COVERAGE_GOLDEN_FHIR, cov.to_fhir
      end

      test "ServiceRequest to_fhir golden output unchanged for representative synthetic record" do
        sr = ServiceRequest.new(
          ien: 242,
          patient_dfn: 100,
          requesting_provider_ien: 101,
          service_requested: "Cardiology consult",
          identifier: "SR-GOLDEN-242",
          status: "active",
          urgency: "ROUTINE",
          referral_type: "rcis",
          authored_on: Date.new(2024, 3, 15),
          reason_for_referral: "Chest pain"
        )

        assert_equal SERVICE_REQUEST_GOLDEN_FHIR, sr.to_fhir
      end

      test "Consent to_fhir golden output unchanged for representative synthetic record" do
        consent = Consent.new(
          id: "consent-golden-242",
          status: "active",
          scope: "patient-privacy",
          patient_dfn: "1",
          performer_ien: 101,
          date_time: Date.new(2024, 1, 10),
          provision_type: "permit",
          provision_action: "access",
          period_start: Date.new(2024, 1, 1),
          period_end: Date.new(2025, 12, 31)
        )

        assert_equal CONSENT_GOLDEN_FHIR, consent.to_fhir
      end
    end
  end
end
