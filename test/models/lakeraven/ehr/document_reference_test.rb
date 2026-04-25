# frozen_string_literal: true

require "test_helper"
require "ostruct"

module Lakeraven
  module EHR
    class DocumentReferenceTest < ActiveSupport::TestCase
      # =============================================================================
      # ATTRIBUTE TESTS
      # =============================================================================

      test "has document attributes" do
        doc = DocumentReference.new(
          id: "doc-1", status: "current",
          type_code: "18842-5", type_display: "Discharge summary",
          subject_patient_dfn: "100", description: "Hospital discharge",
          content_url: "https://example.com/doc.pdf", content_type: "application/pdf"
        )
        assert_equal "doc-1", doc.id
        assert_equal "current", doc.status
        assert_equal "18842-5", doc.type_code
        assert_equal "Discharge summary", doc.type_display
        assert_equal "100", doc.subject_patient_dfn
        assert_equal "Hospital discharge", doc.description
        assert_equal "application/pdf", doc.content_type
        assert_equal "https://example.com/doc.pdf", doc.content_url
      end

      test "defaults status to current" do
        assert_equal "current", DocumentReference.new.status
      end

      test "stores date" do
        dt = DateTime.new(2024, 3, 15, 10, 0)
        doc = DocumentReference.new(date: dt)
        assert_equal dt, doc.date
      end

      test "stores author and category" do
        doc = DocumentReference.new(author_ien: "101", category: "clinical-note")
        assert_equal "101", doc.author_ien
        assert_equal "clinical-note", doc.category
      end

      test "stores description" do
        doc = DocumentReference.new(description: "Cardiology consultation")
        assert_equal "Cardiology consultation", doc.description
      end

      test "stores context_service_request_ien" do
        doc = DocumentReference.new(context_service_request_ien: "500")
        assert_equal "500", doc.context_service_request_ien
      end

      # =============================================================================
      # VALIDATION TESTS
      # =============================================================================

      test "should be valid with required attributes" do
        doc = DocumentReference.new(
          subject_patient_dfn: "12345",
          type_code: "11488-4"
        )
        assert doc.valid?, "DocumentReference should be valid with patient and type code"
      end

      test "should require subject_patient_dfn" do
        doc = DocumentReference.new(type_code: "11488-4")
        refute doc.valid?
        assert doc.errors[:subject_patient_dfn].any?
      end

      test "should require type_code" do
        doc = DocumentReference.new(subject_patient_dfn: "12345")
        refute doc.valid?
        assert doc.errors[:type_code].any?
      end

      test "should validate status if present" do
        doc = DocumentReference.new(
          subject_patient_dfn: "12345",
          type_code: "11488-4",
          status: "invalid"
        )
        refute doc.valid?
        assert_includes doc.errors[:status], "is not included in the list"
      end

      test "should allow blank status" do
        doc = DocumentReference.new(
          subject_patient_dfn: "12345",
          type_code: "11488-4",
          status: nil
        )
        assert doc.valid?
      end

      test "should validate category if present" do
        doc = DocumentReference.new(
          subject_patient_dfn: "12345",
          type_code: "11488-4",
          category: "invalid-category"
        )
        refute doc.valid?
        assert_includes doc.errors[:category], "is not included in the list"
      end

      test "should allow blank category" do
        doc = DocumentReference.new(
          subject_patient_dfn: "12345",
          type_code: "11488-4"
        )
        assert doc.valid?
      end

      # =============================================================================
      # STATUS HELPER TESTS
      # =============================================================================

      test "current? for current status" do
        assert DocumentReference.new(status: "current").current?
      end

      test "current? false for superseded" do
        refute DocumentReference.new(status: "superseded").current?
      end

      test "current? false for entered-in-error" do
        refute DocumentReference.new(status: "entered-in-error").current?
      end

      test "current? false for nil status" do
        doc = DocumentReference.new
        doc.status = nil
        refute doc.current?
      end

      test "superseded? returns true for superseded status" do
        doc = DocumentReference.new(status: "superseded")
        assert doc.superseded?
      end

      test "entered_in_error? returns true for entered-in-error status" do
        doc = DocumentReference.new(status: "entered-in-error")
        assert doc.entered_in_error?
      end

      test "active? returns true for current documents" do
        doc = DocumentReference.new(status: "current")
        assert doc.active?
      end

      test "active? returns false for superseded documents" do
        doc = DocumentReference.new(status: "superseded")
        refute doc.active?
      end

      test "status_display returns human-readable status" do
        doc = DocumentReference.new(status: "current")
        assert_equal "Current", doc.status_display

        doc.status = "superseded"
        assert_equal "Superseded", doc.status_display

        doc.status = "entered-in-error"
        assert_equal "Entered in Error", doc.status_display

        doc.status = nil
        assert_equal "Unknown", doc.status_display
      end

      # =============================================================================
      # CATEGORY HELPER TESTS
      # =============================================================================

      test "category_display returns human-readable category" do
        doc = DocumentReference.new(category: "clinical-note")
        assert_equal "Clinical Note", doc.category_display

        doc.category = "discharge-summary"
        assert_equal "Discharge Summary", doc.category_display

        doc.category = nil
        assert_equal "Unknown", doc.category_display
      end

      test "clinical_note? returns true for clinical-note category" do
        assert DocumentReference.new(category: "clinical-note").clinical_note?
      end

      test "imaging? returns true for imaging category" do
        assert DocumentReference.new(category: "imaging").imaging?
      end

      test "laboratory? returns true for laboratory category" do
        assert DocumentReference.new(category: "laboratory").laboratory?
      end

      # =============================================================================
      # TYPE HELPER TESTS
      # =============================================================================

      test "type_display_from_loinc returns LOINC display for known codes" do
        doc = DocumentReference.new(type_code: "11488-4")
        assert_equal "Consultation Note", doc.type_display_from_loinc

        doc.type_code = "18842-5"
        assert_equal "Discharge Summary", doc.type_display_from_loinc
      end

      test "type_display_from_loinc falls back to type_display for unknown codes" do
        doc = DocumentReference.new(
          type_code: "99999-9",
          type_display: "Custom Document"
        )
        assert_equal "Custom Document", doc.type_display_from_loinc
      end

      # =============================================================================
      # PERSISTENCE TESTS
      # =============================================================================

      test "persisted? returns false for new document" do
        doc = DocumentReference.new(subject_patient_dfn: "12345", type_code: "11488-4")
        refute doc.persisted?
      end

      test "persisted? returns true for document with id" do
        doc = DocumentReference.new(
          id: SecureRandom.uuid,
          subject_patient_dfn: "12345",
          type_code: "11488-4"
        )
        assert doc.persisted?
      end

      # =============================================================================
      # FHIR SERIALIZATION TESTS
      # =============================================================================

      test "to_fhir returns DocumentReference resource" do
        doc = DocumentReference.new(status: "current", subject_patient_dfn: "100")
        fhir = doc.to_fhir
        assert_equal "DocumentReference", fhir[:resourceType]
        assert_equal "current", fhir[:status]
      end

      test "to_fhir includes id" do
        doc = DocumentReference.new(id: "test-uuid", status: "current", subject_patient_dfn: "100")
        fhir = doc.to_fhir
        assert_equal "test-uuid", fhir[:id]
      end

      test "to_fhir includes subject" do
        doc = DocumentReference.new(subject_patient_dfn: "100")
        fhir = doc.to_fhir
        assert_equal "Patient/100", fhir.dig(:subject, :reference)
      end

      test "to_fhir includes type with LOINC coding" do
        doc = DocumentReference.new(
          subject_patient_dfn: "12345",
          type_code: "11488-4",
          type_display: "Consultation Note"
        )
        fhir = doc.to_fhir

        assert_not_nil fhir[:type]
        coding = fhir[:type][:coding].first
        assert_equal "11488-4", coding[:code]
        assert_equal "http://loinc.org", coding[:system]
        assert_equal "Consultation Note", coding[:display]
      end

      test "to_fhir includes category" do
        doc = DocumentReference.new(
          subject_patient_dfn: "12345",
          type_code: "11488-4",
          category: "clinical-note"
        )
        fhir = doc.to_fhir

        assert fhir[:category].any?
        coding = fhir[:category].first[:coding].first
        assert_equal "clinical-note", coding[:code]
        assert_equal "Clinical Note", coding[:display]
      end

      test "to_fhir includes author reference" do
        doc = DocumentReference.new(
          subject_patient_dfn: "12345",
          type_code: "11488-4",
          author_ien: "101"
        )
        fhir = doc.to_fhir

        assert fhir[:author].any?
        author = fhir[:author].first
        assert_includes author[:reference], "Practitioner"
        assert_includes author[:reference], "101"
      end

      test "to_fhir includes content with URL" do
        doc = DocumentReference.new(
          content_url: "https://example.com/doc.pdf",
          content_type: "application/pdf"
        )
        fhir = doc.to_fhir
        assert_equal "https://example.com/doc.pdf", fhir[:content].first.dig(:attachment, :url)
        assert_equal "application/pdf", fhir[:content].first.dig(:attachment, :contentType)
      end

      test "to_fhir returns empty content array when no URL" do
        doc = DocumentReference.new(content_url: nil)
        fhir = doc.to_fhir
        assert_equal [], fhir[:content]
      end

      test "to_fhir includes description" do
        doc = DocumentReference.new(
          subject_patient_dfn: "12345",
          type_code: "11488-4",
          description: "Cardiology consultation"
        )
        fhir = doc.to_fhir
        assert_equal "Cardiology consultation", fhir[:description]
      end

      test "to_fhir includes date" do
        doc = DocumentReference.new(
          subject_patient_dfn: "12345",
          type_code: "11488-4",
          date: Date.parse("2024-06-15")
        )
        fhir = doc.to_fhir
        assert_equal "2024-06-15", fhir[:date]
      end

      test "to_fhir includes context for service request" do
        doc = DocumentReference.new(
          subject_patient_dfn: "12345",
          type_code: "11488-4",
          context_service_request_ien: "500"
        )
        fhir = doc.to_fhir

        assert_not_nil fhir[:context]
        related = fhir[:context][:related].first
        assert_includes related[:reference], "ServiceRequest"
        assert_includes related[:reference], "500"
      end

      test "to_fhir omits subject when subject_patient_dfn is nil" do
        doc = DocumentReference.new(subject_patient_dfn: nil)
        fhir = doc.to_fhir
        assert_nil fhir[:subject]
      end

      test "to_fhir omits description when nil" do
        doc = DocumentReference.new(description: nil)
        fhir = doc.to_fhir
        refute fhir.key?(:description)
      end

      test "resource_class returns DocumentReference" do
        assert_equal "DocumentReference", DocumentReference.resource_class
      end

      test "from_fhir_attributes extracts attributes" do
        fhir_resource = OpenStruct.new(
          status: "current",
          type: OpenStruct.new(
            coding: [ OpenStruct.new(code: "11488-4", display: "Consultation Note") ]
          ),
          category: [
            OpenStruct.new(coding: [ OpenStruct.new(code: "clinical-note") ])
          ],
          subject: OpenStruct.new(reference: "Patient/12345"),
          date: "2024-06-15",
          description: "Test description"
        )

        attrs = DocumentReference.from_fhir_attributes(fhir_resource)
        assert_equal "current", attrs[:status]
        assert_equal "11488-4", attrs[:type_code]
        assert_equal "Consultation Note", attrs[:type_display]
        assert_equal "clinical-note", attrs[:category]
        assert_equal "12345", attrs[:subject_patient_dfn]
        assert_equal Date.parse("2024-06-15"), attrs[:date]
        assert_equal "Test description", attrs[:description]
      end

      test "from_fhir creates document reference from FHIR resource" do
        fhir_resource = OpenStruct.new(
          status: "current",
          type: OpenStruct.new(
            coding: [ OpenStruct.new(code: "11488-4", display: "Consultation Note") ]
          ),
          subject: OpenStruct.new(reference: "Patient/12345")
        )

        doc = DocumentReference.from_fhir(fhir_resource)
        assert doc.is_a?(DocumentReference)
        assert_equal "current", doc.status
        assert_equal "11488-4", doc.type_code
        assert_equal "12345", doc.subject_patient_dfn
      end

      # =============================================================================
      # US CORE COMPLIANCE TESTS
      # =============================================================================

      test "document reference FHIR is US Core compliant" do
        doc = DocumentReference.new(
          subject_patient_dfn: "12345",
          type_code: "11488-4",
          type_display: "Consultation Note",
          category: "clinical-note",
          status: "current"
        )
        fhir = doc.to_fhir

        assert fhir[:status].present?, "US Core requires status"
        assert fhir[:type].present?, "US Core requires type"
        assert fhir[:category].any?, "US Core requires category"
        assert fhir[:subject].present?, "US Core requires subject"
      end

      test "document type uses LOINC coding system" do
        doc = DocumentReference.new(
          subject_patient_dfn: "12345",
          type_code: "11488-4"
        )
        fhir = doc.to_fhir

        coding = fhir[:type][:coding].first
        assert_equal "http://loinc.org", coding[:system]
      end

      test "document reference FHIR can be serialized to JSON" do
        doc = DocumentReference.new(
          subject_patient_dfn: "12345",
          type_code: "11488-4",
          category: "clinical-note"
        )

        assert_nothing_raised do
          doc.to_fhir.to_json
        end
      end

      # =============================================================================
      # EDGE CASE TESTS
      # =============================================================================

      test "handles nil author in FHIR" do
        doc = DocumentReference.new(
          subject_patient_dfn: "12345",
          type_code: "11488-4",
          author_ien: nil
        )
        fhir = doc.to_fhir
        assert_equal [], fhir[:author]
      end

      test "handles nil content in FHIR" do
        doc = DocumentReference.new(
          subject_patient_dfn: "12345",
          type_code: "11488-4",
          content_url: nil,
          content_type: nil
        )
        fhir = doc.to_fhir
        assert_equal [], fhir[:content]
      end

      test "handles nil context in FHIR" do
        doc = DocumentReference.new(
          subject_patient_dfn: "12345",
          type_code: "11488-4",
          context_service_request_ien: nil
        )
        fhir = doc.to_fhir
        assert_nil fhir[:context]
      end

      test "handles nil category in FHIR" do
        doc = DocumentReference.new(
          subject_patient_dfn: "12345",
          type_code: "11488-4",
          category: nil
        )
        fhir = doc.to_fhir
        assert_equal [], fhir[:category]
      end
    end
  end
end
