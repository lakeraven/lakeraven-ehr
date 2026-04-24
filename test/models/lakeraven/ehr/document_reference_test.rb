# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class DocumentReferenceTest < ActiveSupport::TestCase
      test "has document attributes" do
        doc = DocumentReference.new(
          id: "doc-1", status: "current",
          type_code: "18842-5", type_display: "Discharge summary",
          subject_patient_dfn: "100", description: "Hospital discharge",
          content_url: "https://example.com/doc.pdf", content_type: "application/pdf"
        )
        assert_equal "doc-1", doc.id
        assert_equal "Discharge summary", doc.type_display
        assert_equal "Hospital discharge", doc.description
        assert_equal "application/pdf", doc.content_type
      end

      test "defaults status to current" do
        assert_equal "current", DocumentReference.new.status
      end

      test "current? for current status" do
        assert DocumentReference.new(status: "current").current?
      end

      test "current? false for superseded" do
        refute DocumentReference.new(status: "superseded").current?
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

      test "to_fhir returns DocumentReference resource" do
        doc = DocumentReference.new(status: "current", subject_patient_dfn: "100")
        fhir = doc.to_fhir
        assert_equal "DocumentReference", fhir[:resourceType]
        assert_equal "current", fhir[:status]
      end

      test "to_fhir includes subject" do
        doc = DocumentReference.new(subject_patient_dfn: "100")
        fhir = doc.to_fhir
        assert_equal "Patient/100", fhir.dig(:subject, :reference)
      end

      test "to_fhir includes type" do
        doc = DocumentReference.new(type_display: "Discharge summary")
        fhir = doc.to_fhir
        assert_equal "Discharge summary", fhir.dig(:type, :text)
      end

      test "to_fhir includes content with URL" do
        doc = DocumentReference.new(
          content_url: "https://example.com/doc.pdf",
          content_type: "application/pdf"
        )
        fhir = doc.to_fhir
        assert_equal "https://example.com/doc.pdf", fhir[:content].first.dig(:attachment, :url)
      end

      test "to_fhir returns empty content array when no URL" do
        doc = DocumentReference.new(content_url: nil)
        fhir = doc.to_fhir
        assert_equal [], fhir[:content]
      end
    end
  end
end
