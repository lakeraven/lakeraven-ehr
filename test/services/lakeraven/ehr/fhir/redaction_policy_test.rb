# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    module FHIR
      class RedactionPolicyTest < ActiveSupport::TestCase
        # =============================================================================
        # FULL VIEW (no redaction)
        # =============================================================================

        test "full view returns resource unchanged" do
          policy = RedactionPolicy.new(view: :full)
          resource = { resourceType: "Patient", id: "1", name: [ { family: "Doe" } ],
                       identifier: [ { system: "ssn", value: "111-22-3333" } ] }

          result = policy.apply(resource)

          assert_equal "1", result[:id]
          assert_equal "111-22-3333", result[:identifier].first[:value]
        end

        # =============================================================================
        # PATIENT_SAFE VIEW (mask SSN, keep name/DOB/address)
        # =============================================================================

        test "patient_safe view masks SSN" do
          policy = RedactionPolicy.new(view: :patient_safe)
          resource = build_patient_resource(ssn: "111-22-3333")

          result = policy.apply(resource)

          ssn_id = result[:identifier]&.find { |i| i[:system]&.include?("ssn") }
          if ssn_id
            refute_equal "111-22-3333", ssn_id[:value]
            assert_includes ssn_id[:value], "***"
          end
        end

        test "patient_safe view keeps name" do
          policy = RedactionPolicy.new(view: :patient_safe)
          resource = build_patient_resource

          result = policy.apply(resource)

          assert result[:name].present?
        end

        # =============================================================================
        # EXTERNAL VIEW (redact SSN, DFN, tribal enrollment)
        # =============================================================================

        test "external view removes SSN" do
          policy = RedactionPolicy.new(view: :external)
          resource = build_patient_resource(ssn: "111-22-3333")

          result = policy.apply(resource)

          ssn_ids = result[:identifier]&.select { |i| i[:system]&.include?("ssn") }
          assert_empty(ssn_ids || [])
        end

        test "external view removes tribal enrollment extension" do
          policy = RedactionPolicy.new(view: :external)
          resource = build_patient_resource(tribal: "ANLC-12345")

          result = policy.apply(resource)

          tribal_exts = (result[:extension] || []).select { |e| e[:url]&.include?("tribal") }
          assert_empty tribal_exts
        end

        # =============================================================================
        # RESEARCH VIEW (redact all direct identifiers)
        # =============================================================================

        test "research view removes name" do
          policy = RedactionPolicy.new(view: :research)
          resource = build_patient_resource

          result = policy.apply(resource)

          assert_empty(result[:name] || [])
        end

        test "research view removes birthDate" do
          policy = RedactionPolicy.new(view: :research)
          resource = build_patient_resource

          result = policy.apply(resource)

          assert_nil result[:birthDate]
        end

        test "research view removes address" do
          policy = RedactionPolicy.new(view: :research)
          resource = build_patient_resource

          result = policy.apply(resource)

          assert_empty(result[:address] || [])
        end

        test "research view removes all identifiers" do
          policy = RedactionPolicy.new(view: :research)
          resource = build_patient_resource(ssn: "111-22-3333")

          result = policy.apply(resource)

          assert_empty(result[:identifier] || [])
        end

        test "research view removes SOGI extensions" do
          policy = RedactionPolicy.new(view: :research)
          resource = build_patient_resource(sogi: true)

          result = policy.apply(resource)

          sogi_exts = (result[:extension] || []).select { |e|
            e[:url]&.include?("sexualOrientation") || e[:url]&.include?("genderIdentity")
          }
          assert_empty sogi_exts
        end

        # =============================================================================
        # RESOURCE TYPE AGNOSTIC
        # =============================================================================

        test "policy works on non-Patient resources" do
          policy = RedactionPolicy.new(view: :full)
          resource = { resourceType: "Condition", id: "1", code: { coding: [] } }

          result = policy.apply(resource)

          assert_equal "Condition", result[:resourceType]
        end

        # =============================================================================
        # VIEWS LIST
        # =============================================================================

        test "VIEWS includes all four views" do
          assert_includes RedactionPolicy::VIEWS, :full
          assert_includes RedactionPolicy::VIEWS, :patient_safe
          assert_includes RedactionPolicy::VIEWS, :external
          assert_includes RedactionPolicy::VIEWS, :research
        end

        private

        def build_patient_resource(ssn: nil, tribal: nil, sogi: false)
          resource = {
            resourceType: "Patient",
            id: "1",
            name: [ { use: "official", family: "Doe", given: [ "John" ] } ],
            gender: "male",
            birthDate: "1980-01-15",
            address: [ { line: [ "123 Main St" ], city: "Anchorage", state: "AK" } ],
            telecom: [ { system: "phone", value: "907-555-1234" } ],
            identifier: [ { use: "usual", system: "urn:oid:2.16.840.1.113883.4.349", value: "1" } ],
            extension: []
          }

          if ssn
            resource[:identifier] << { use: "secondary", system: "http://hl7.org/fhir/sid/us-ssn", value: ssn }
          end

          if tribal
            resource[:extension] << {
              url: "http://hl7.org/fhir/us/core/StructureDefinition/tribal-affiliation",
              valueString: tribal
            }
          end

          if sogi
            resource[:extension] << { url: "http://hl7.org/fhir/StructureDefinition/patient-sexualOrientation", valueString: "Heterosexual" }
            resource[:extension] << { url: "http://hl7.org/fhir/StructureDefinition/patient-genderIdentity", valueString: "Male" }
          end

          resource
        end
      end
    end
  end
end
