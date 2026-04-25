# frozen_string_literal: true

require "test_helper"
require "ostruct"

module Lakeraven
  module EHR
    class ConditionTest < ActiveSupport::TestCase
      # -- Attributes ----------------------------------------------------------

      test "has clinical attributes" do
        c = Condition.new(
          ien: "1", patient_dfn: "100", code: "E11.9",
          display: "Type 2 diabetes mellitus", clinical_status: "active",
          category: "problem-list-item", severity: "moderate"
        )
        assert_equal "E11.9", c.code
        assert_equal "Type 2 diabetes mellitus", c.display
        assert_equal "active", c.clinical_status
        assert_equal "problem-list-item", c.category
        assert_equal "moderate", c.severity
      end

      test "stores onset_datetime" do
        onset = DateTime.new(2020, 6, 15)
        c = Condition.new(onset_datetime: onset)
        assert_equal onset, c.onset_datetime
      end

      test "stores recorded_date" do
        c = Condition.new(recorded_date: Date.new(2024, 1, 15))
        assert_equal Date.new(2024, 1, 15), c.recorded_date
      end

      test "stores verification_status" do
        c = Condition.new(verification_status: "confirmed")
        assert_equal "confirmed", c.verification_status
      end

      # -- Predicates ----------------------------------------------------------

      test "active? for active status" do
        assert Condition.new(clinical_status: "active").active?
      end

      test "active? false for inactive" do
        refute Condition.new(clinical_status: "inactive").active?
      end

      test "active? false for resolved" do
        refute Condition.new(clinical_status: "resolved").active?
      end

      test "problem_list_item? for problem-list-item category" do
        assert Condition.new(category: "problem-list-item").problem_list_item?
      end

      test "problem_list_item? false for encounter-diagnosis" do
        refute Condition.new(category: "encounter-diagnosis").problem_list_item?
      end

      test "resolved? for resolved status" do
        assert Condition.new(clinical_status: "resolved").resolved?
      end

      test "resolved? false for active" do
        refute Condition.new(clinical_status: "active").resolved?
      end

      # -- Class methods -------------------------------------------------------

      test "for_patient returns array" do
        results = Condition.for_patient(1)
        assert_kind_of Array, results
      end

      # -- Gateway DI ----------------------------------------------------------

      test "gateway is configurable" do
        assert Condition.respond_to?(:gateway)
        assert Condition.respond_to?(:gateway=)
      end

      test "gateway defaults to ConditionGateway" do
        assert_equal ConditionGateway, Condition.gateway
      end

      test "for_patient delegates to gateway" do
        mock_gw = Object.new
        def mock_gw.for_patient(_dfn)
          [ Lakeraven::EHR::Condition.new(ien: "99", patient_dfn: "1", display: "MOCK") ]
        end

        original = Condition.gateway
        begin
          Condition.gateway = mock_gw
          results = Condition.for_patient(1)
          assert_equal 1, results.length
          assert_equal "MOCK", results.first.display
        ensure
          Condition.gateway = original
        end
      end

      # -- FHIR serialization --------------------------------------------------

      test "to_fhir returns Condition resource" do
        c = Condition.new(ien: "42", patient_dfn: "100")
        fhir = c.to_fhir
        assert_equal "Condition", fhir[:resourceType]
        assert_equal "42", fhir[:id]
        assert_equal "Patient/100", fhir.dig(:subject, :reference)
      end

      test "to_fhir includes clinicalStatus" do
        c = Condition.new(ien: "1", patient_dfn: "100", clinical_status: "active")
        fhir = c.to_fhir
        assert_equal "active", fhir.dig(:clinicalStatus, :coding, 0, :code)
      end

      test "to_fhir includes code" do
        c = Condition.new(ien: "1", patient_dfn: "100", code: "E11.9", display: "Diabetes")
        fhir = c.to_fhir
        assert_equal "E11.9", fhir.dig(:code, :coding, 0, :code)
        assert_equal "Diabetes", fhir.dig(:code, :text)
      end

      test "to_fhir includes category" do
        c = Condition.new(ien: "1", patient_dfn: "100", category: "problem-list-item")
        fhir = c.to_fhir
        assert fhir[:category]&.any?
      end

      test "to_fhir omits subject when no patient_dfn" do
        c = Condition.new(ien: "42")
        fhir = c.to_fhir
        assert_nil fhir[:subject]
      end

      # -- validations -----------------------------------------------------------

      test "validates patient_dfn presence" do
        c = Condition.new(display: "Diabetes")
        refute c.valid?
        assert_includes c.errors[:patient_dfn], "can't be blank"
      end

      test "validates display presence" do
        c = Condition.new(patient_dfn: "123")
        refute c.valid?
        assert_includes c.errors[:display], "can't be blank"
      end

      test "validates clinical_status values" do
        c = Condition.new(patient_dfn: "123", display: "Diabetes", clinical_status: "invalid")
        refute c.valid?
        assert_includes c.errors[:clinical_status], "is not included in the list"
      end

      test "allows valid clinical_status values" do
        %w[active recurrence relapse inactive remission resolved].each do |status|
          c = Condition.new(patient_dfn: "123", display: "Diabetes", clinical_status: status)
          assert c.valid?, "Expected #{status} to be valid"
        end
      end

      test "validates category values" do
        c = Condition.new(patient_dfn: "123", display: "Diabetes", category: "invalid")
        refute c.valid?
        assert_includes c.errors[:category], "is not included in the list"
      end

      test "allows valid category values" do
        %w[problem-list-item encounter-diagnosis health-concern].each do |cat|
          c = Condition.new(patient_dfn: "123", display: "Diabetes", category: cat)
          assert c.valid?, "Expected #{cat} to be valid"
        end
      end

      # -- resource_class --------------------------------------------------------

      test "resource_class returns Condition" do
        assert_equal "Condition", Condition.resource_class
      end

      # -- persisted? ------------------------------------------------------------

      test "persisted? true when ien present" do
        c = Condition.new(ien: "123", patient_dfn: "456", display: "Test")
        assert c.persisted?
      end

      test "persisted? false when ien blank" do
        c = Condition.new(patient_dfn: "456", display: "Test")
        refute c.persisted?
      end

      # -- to_fhir includes clinicalStatus system --------------------------------

      test "to_fhir clinicalStatus includes system" do
        c = Condition.new(ien: "1", patient_dfn: "100", clinical_status: "active")
        fhir = c.to_fhir
        coding = fhir.dig(:clinicalStatus, :coding, 0)
        assert_equal "http://terminology.hl7.org/CodeSystem/condition-clinical", coding[:system]
      end

      # -- to_fhir includes ICD-10 code system URL -------------------------------

      test "to_fhir includes ICD-10 code system URL" do
        c = Condition.new(
          ien: "1", patient_dfn: "100",
          code: "E11.9", code_system: "icd10", display: "Type 2 diabetes"
        )
        fhir = c.to_fhir
        coding = fhir.dig(:code, :coding, 0)
        assert_equal "http://hl7.org/fhir/sid/icd-10-cm", coding[:system]
      end

      test "to_fhir includes SNOMED code system URL" do
        c = Condition.new(
          ien: "1", patient_dfn: "100",
          code: "44054006", code_system: "snomed", display: "Type 2 diabetes"
        )
        fhir = c.to_fhir
        coding = fhir.dig(:code, :coding, 0)
        assert_equal "http://snomed.info/sct", coding[:system]
      end

      # -- to_fhir includes severity ---------------------------------------------

      test "to_fhir includes severity with SNOMED code" do
        c = Condition.new(
          ien: "1", patient_dfn: "100", display: "Diabetes", severity: "moderate"
        )
        fhir = c.to_fhir
        assert_equal "6736007", fhir.dig(:severity, :coding, 0, :code)
        assert_equal "Moderate", fhir.dig(:severity, :coding, 0, :display)
      end

      # -- from_fhir_attributes --------------------------------------------------

      test "from_fhir_attributes extracts attributes" do
        fhir_resource = OpenStruct.new(
          code: OpenStruct.new(
            coding: [ OpenStruct.new(code: "E11.9", display: "Type 2 diabetes") ],
            text: "Type 2 diabetes"
          ),
          clinicalStatus: OpenStruct.new(
            coding: [ OpenStruct.new(code: "active") ]
          ),
          verificationStatus: OpenStruct.new(
            coding: [ OpenStruct.new(code: "confirmed") ]
          ),
          category: [ OpenStruct.new(
            coding: [ OpenStruct.new(code: "problem-list-item") ]
          ) ]
        )

        attrs = Condition.from_fhir_attributes(fhir_resource)

        assert_equal "E11.9", attrs[:code]
        assert_equal "Type 2 diabetes", attrs[:display]
        assert_equal "active", attrs[:clinical_status]
        assert_equal "confirmed", attrs[:verification_status]
        assert_equal "problem-list-item", attrs[:category]
      end
    end
  end
end
