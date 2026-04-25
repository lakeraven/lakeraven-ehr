# frozen_string_literal: true

require "test_helper"
require "ostruct"

module Lakeraven
  module EHR
    class RelatedPersonTest < ActiveSupport::TestCase
      # =============================================================================
      # VALIDATION TESTS
      # =============================================================================

      test "should be valid with required attributes" do
        person = RelatedPerson.new(patient_dfn: "12345", name: "Jane Doe", relationship: "spouse")
        assert person.valid?, "RelatedPerson should be valid with patient, name, and relationship"
      end

      test "should require patient_dfn" do
        person = RelatedPerson.new(name: "Jane Doe", relationship: "spouse")
        refute person.valid?
        assert person.errors[:patient_dfn].any?
      end

      test "should require name" do
        person = RelatedPerson.new(patient_dfn: "12345", relationship: "spouse")
        refute person.valid?
        assert person.errors[:name].any?
      end

      test "should require relationship" do
        person = RelatedPerson.new(patient_dfn: "12345", name: "Jane Doe")
        refute person.valid?
        assert person.errors[:relationship].any?
      end

      test "should validate relationship is in allowed list" do
        person = RelatedPerson.new(patient_dfn: "12345", name: "Jane Doe", relationship: "invalid")
        refute person.valid?
        assert_includes person.errors[:relationship], "is not included in the list"
      end

      # =============================================================================
      # STATUS HELPER TESTS
      # =============================================================================

      test "active? returns true for active persons" do
        person = RelatedPerson.new(patient_dfn: "12345", name: "Jane Doe", relationship: "spouse", active: true)
        assert person.active?
      end

      test "active? returns false for inactive persons" do
        person = RelatedPerson.new(patient_dfn: "12345", name: "Jane Doe", relationship: "spouse", active: false)
        refute person.active?
      end

      test "within_period? returns true when no period set" do
        person = RelatedPerson.new(patient_dfn: "12345", name: "Jane Doe", relationship: "spouse")
        assert person.within_period?
      end

      test "within_period? returns true when within period" do
        person = RelatedPerson.new(
          patient_dfn: "12345", name: "Jane Doe", relationship: "spouse",
          period_start: Date.current - 1.year, period_end: Date.current + 1.year
        )
        assert person.within_period?
      end

      test "within_period? returns false when before period" do
        person = RelatedPerson.new(
          patient_dfn: "12345", name: "Jane Doe", relationship: "spouse",
          period_start: Date.current + 1.month
        )
        refute person.within_period?
      end

      test "within_period? returns false when after period" do
        person = RelatedPerson.new(
          patient_dfn: "12345", name: "Jane Doe", relationship: "spouse",
          period_end: Date.current - 1.month
        )
        refute person.within_period?
      end

      test "valid_for_authorization? checks active and period" do
        person = RelatedPerson.new(
          patient_dfn: "12345", name: "Jane Doe", relationship: "spouse", active: true
        )
        assert person.valid_for_authorization?

        person.active = false
        refute person.valid_for_authorization?
      end

      # =============================================================================
      # RELATIONSHIP HELPER TESTS
      # =============================================================================

      test "relationship_display returns human-readable relationship" do
        person = RelatedPerson.new(relationship: "parent")
        assert_equal "Parent", person.relationship_display

        person.relationship = "spouse"
        assert_equal "Spouse", person.relationship_display

        person.relationship = "guardian"
        assert_equal "Guardian", person.relationship_display

        person.relationship = nil
        assert_equal "Unknown", person.relationship_display
      end

      test "guardian? returns true for guardians" do
        assert RelatedPerson.new(relationship: "guardian").guardian?
      end

      test "caregiver? returns true for caregivers" do
        assert RelatedPerson.new(relationship: "caregiver").caregiver?
      end

      test "family_member? returns true for family relationships" do
        assert RelatedPerson.new(relationship: "parent").family_member?
        assert RelatedPerson.new(relationship: "spouse").family_member?
        assert RelatedPerson.new(relationship: "child").family_member?
        assert RelatedPerson.new(relationship: "sibling").family_member?
        refute RelatedPerson.new(relationship: "friend").family_member?
        refute RelatedPerson.new(relationship: "guardian").family_member?
      end

      # =============================================================================
      # PERSISTENCE TESTS
      # =============================================================================

      test "persisted? returns false for new person without id" do
        person = RelatedPerson.new(patient_dfn: "12345", name: "Jane Doe", relationship: "spouse")
        refute person.persisted?
      end

      test "persisted? returns true when id present" do
        person = RelatedPerson.new(id: "42")
        assert person.persisted?
      end

      # =============================================================================
      # FHIR SERIALIZATION TESTS
      # =============================================================================

      test "to_fhir returns valid FHIR RelatedPerson resource" do
        person = RelatedPerson.new(
          id: "42", patient_dfn: "12345", name: "Jane Doe",
          relationship: "spouse", active: true
        )
        fhir = person.to_fhir

        assert_equal "RelatedPerson", fhir[:resourceType]
        assert_equal "42", fhir[:id]
        assert_equal true, fhir[:active]
      end

      test "to_fhir includes patient reference" do
        person = RelatedPerson.new(patient_dfn: "12345", name: "Jane Doe", relationship: "spouse")
        fhir = person.to_fhir

        assert_not_nil fhir[:patient]
        assert_equal "Patient/12345", fhir[:patient][:reference]
      end

      test "to_fhir includes relationship coding" do
        person = RelatedPerson.new(patient_dfn: "12345", name: "Jane Doe", relationship: "guardian")
        fhir = person.to_fhir

        assert fhir[:relationship].any?
        relationship = fhir[:relationship].first
        coding = relationship[:coding].first
        assert_equal "guardian", coding[:code]
        assert_equal "Guardian", coding[:display]
      end

      test "to_fhir includes name" do
        person = RelatedPerson.new(patient_dfn: "12345", name: "Jane Doe", relationship: "spouse")
        fhir = person.to_fhir

        assert fhir[:name].any?
        assert_equal "Jane Doe", fhir[:name].first[:text]
      end

      test "to_fhir includes telecom" do
        person = RelatedPerson.new(
          patient_dfn: "12345", name: "Jane Doe", relationship: "spouse",
          phone: "555-1234", email: "jane@example.com"
        )
        fhir = person.to_fhir

        assert_equal 2, fhir[:telecom].count
        phone = fhir[:telecom].find { |t| t[:system] == "phone" }
        email = fhir[:telecom].find { |t| t[:system] == "email" }
        assert_equal "555-1234", phone[:value]
        assert_equal "jane@example.com", email[:value]
      end

      test "to_fhir includes period" do
        person = RelatedPerson.new(
          patient_dfn: "12345", name: "Jane Doe", relationship: "spouse",
          period_start: Date.parse("2024-01-01"), period_end: Date.parse("2024-12-31")
        )
        fhir = person.to_fhir

        assert_not_nil fhir[:period]
        assert_equal "2024-01-01", fhir[:period][:start]
        assert_equal "2024-12-31", fhir[:period][:end]
      end

      test "resource_class returns RelatedPerson" do
        assert_equal "RelatedPerson", RelatedPerson.resource_class
      end

      test "from_fhir_attributes extracts attributes" do
        fhir_resource = OpenStruct.new(
          active: true,
          patient: OpenStruct.new(reference: "Patient/12345"),
          relationship: [ OpenStruct.new(coding: [ OpenStruct.new(code: "guardian") ]) ],
          name: [ OpenStruct.new(text: "Jane Guardian") ]
        )

        attrs = RelatedPerson.from_fhir_attributes(fhir_resource)
        assert_equal true, attrs[:active]
        assert_equal "12345", attrs[:patient_dfn]
        assert_equal "guardian", attrs[:relationship]
        assert_equal "Jane Guardian", attrs[:name]
      end

      test "from_fhir creates related person from FHIR resource" do
        fhir_resource = OpenStruct.new(
          active: true,
          patient: OpenStruct.new(reference: "Patient/12345"),
          relationship: [ OpenStruct.new(coding: [ OpenStruct.new(code: "spouse") ]) ],
          name: [ OpenStruct.new(text: "Jane Spouse") ]
        )

        person = RelatedPerson.from_fhir(fhir_resource)
        assert person.is_a?(RelatedPerson)
        assert_equal "12345", person.patient_dfn
        assert_equal "spouse", person.relationship
      end

      # =============================================================================
      # EDGE CASE TESTS
      # =============================================================================

      test "handles nil period in FHIR" do
        person = RelatedPerson.new(
          patient_dfn: "12345", name: "Jane Doe", relationship: "spouse",
          period_start: nil, period_end: nil
        )
        fhir = person.to_fhir

        assert_nil fhir[:period]
      end

      test "handles empty telecom in FHIR" do
        person = RelatedPerson.new(
          patient_dfn: "12345", name: "Jane Doe", relationship: "spouse",
          phone: nil, email: nil
        )
        fhir = person.to_fhir

        assert_equal [], fhir[:telecom]
      end
    end
  end
end
