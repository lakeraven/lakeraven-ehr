# frozen_string_literal: true

require "test_helper"
require "ostruct"

module Lakeraven
  module EHR
    class CommunicationTest < ActiveSupport::TestCase
      # =============================================================================
      # VALIDATION TESTS
      # =============================================================================

      test "should be valid with required attributes" do
        communication = Communication.new(
          subject_patient_dfn: "12345",
          sender_type: "Practitioner",
          sender_id: "101",
          payload_content: "Test message"
        )
        assert communication.valid?, "Communication should be valid with required attributes"
      end

      test "should require subject_patient_dfn" do
        communication = Communication.new(
          sender_type: "Practitioner",
          sender_id: "101",
          payload_content: "Test message"
        )
        refute communication.valid?
        assert communication.errors[:subject_patient_dfn].any?
      end

      test "should require sender_id" do
        communication = Communication.new(
          subject_patient_dfn: "12345",
          sender_type: "Practitioner",
          payload_content: "Test message"
        )
        refute communication.valid?
        assert communication.errors[:sender_id].any?
      end

      test "should require payload_content" do
        communication = Communication.new(
          subject_patient_dfn: "12345",
          sender_type: "Practitioner",
          sender_id: "101"
        )
        refute communication.valid?
        assert communication.errors[:payload_content].any?
      end

      test "should validate status is in allowed list" do
        communication = Communication.new(
          subject_patient_dfn: "12345",
          sender_type: "Practitioner",
          sender_id: "101",
          payload_content: "Test",
          status: "invalid"
        )
        refute communication.valid?
        assert_includes communication.errors[:status], "is not included in the list"
      end

      test "should validate priority is in allowed list" do
        communication = Communication.new(
          subject_patient_dfn: "12345",
          sender_type: "Practitioner",
          sender_id: "101",
          payload_content: "Test",
          priority: "invalid"
        )
        refute communication.valid?
        assert_includes communication.errors[:priority], "is not included in the list"
      end

      test "should validate category is in allowed list" do
        communication = Communication.new(
          subject_patient_dfn: "12345",
          sender_type: "Practitioner",
          sender_id: "101",
          payload_content: "Test",
          category: "invalid"
        )
        refute communication.valid?
        assert_includes communication.errors[:category], "is not included in the list"
      end

      # =============================================================================
      # STATUS HELPER TESTS
      # =============================================================================

      test "draft? returns true for preparation status" do
        communication = Communication.new(status: "preparation")
        assert communication.draft?
      end

      test "in_progress? returns true for in-progress status" do
        communication = Communication.new(status: "in-progress")
        assert communication.in_progress?
      end

      test "completed? returns true for completed status" do
        communication = Communication.new(status: "completed")
        assert communication.completed?
      end

      test "on_hold? returns true for on-hold status" do
        communication = Communication.new(status: "on-hold")
        assert communication.on_hold?
      end

      test "stopped? returns true for stopped status" do
        communication = Communication.new(status: "stopped")
        assert communication.stopped?
      end

      test "status_display returns human-readable status" do
        communication = Communication.new(status: "completed")
        assert_equal "Completed", communication.status_display

        communication.status = "in-progress"
        assert_equal "In Progress", communication.status_display
      end

      test "status_display returns Unknown for nil status" do
        communication = Communication.new(status: nil)
        assert_equal "Unknown", communication.status_display
      end

      # =============================================================================
      # PRIORITY HELPER TESTS
      # =============================================================================

      test "routine? returns true for routine priority" do
        communication = Communication.new(priority: "routine")
        assert communication.routine?
      end

      test "urgent? returns true for urgent priority" do
        communication = Communication.new(priority: "urgent")
        assert communication.urgent?
      end

      test "asap? returns true for asap priority" do
        communication = Communication.new(priority: "asap")
        assert communication.asap?
      end

      test "stat? returns true for stat priority" do
        communication = Communication.new(priority: "stat")
        assert communication.stat?
      end

      test "priority_display returns human-readable priority" do
        communication = Communication.new(priority: "stat")
        assert_equal "Stat", communication.priority_display
      end

      test "priority_display returns Unknown for nil priority" do
        communication = Communication.new(priority: nil)
        assert_equal "Unknown", communication.priority_display
      end

      # =============================================================================
      # CATEGORY HELPER TESTS
      # =============================================================================

      test "category_display returns human-readable category" do
        communication = Communication.new(category: "alert")
        assert_equal "Alert", communication.category_display

        communication.category = "notification"
        assert_equal "Notification", communication.category_display
      end

      test "alert? returns true for alert category" do
        assert Communication.new(category: "alert").alert?
      end

      test "notification? returns true for notification category" do
        assert Communication.new(category: "notification").notification?
      end

      test "reminder? returns true for reminder category" do
        assert Communication.new(category: "reminder").reminder?
      end

      test "instruction? returns true for instruction category" do
        assert Communication.new(category: "instruction").instruction?
      end

      # =============================================================================
      # THREADING HELPERS
      # =============================================================================

      test "root_message? returns true when no parent_message_id" do
        communication = Communication.new(parent_message_id: nil)
        assert communication.root_message?
      end

      test "root_message? returns false when parent_message_id present" do
        communication = Communication.new(parent_message_id: "abc-123")
        refute communication.root_message?
      end

      test "reply? returns true when parent_message_id present" do
        communication = Communication.new(parent_message_id: "abc-123")
        assert communication.reply?
      end

      test "reply? returns false when no parent_message_id" do
        communication = Communication.new(parent_message_id: nil)
        refute communication.reply?
      end

      # =============================================================================
      # PERSISTENCE TESTS
      # =============================================================================

      test "persisted? returns false for new communication without ien" do
        communication = Communication.new(subject_patient_dfn: "12345", payload_content: "Test")
        refute communication.persisted?
      end

      test "persisted? returns true when ien present" do
        communication = Communication.new(ien: "999")
        assert communication.persisted?
      end

      # =============================================================================
      # FHIR SERIALIZATION TESTS
      # =============================================================================

      test "to_fhir returns valid FHIR Communication resource" do
        communication = Communication.new(
          ien: "42",
          subject_patient_dfn: "12345",
          sender_type: "Practitioner",
          sender_id: "101",
          status: "completed",
          payload_content: "Test message"
        )
        fhir = communication.to_fhir

        assert_equal "Communication", fhir[:resourceType]
        assert_equal "42", fhir[:id]
        assert_equal "completed", fhir[:status]
      end

      test "to_fhir includes subject reference" do
        communication = Communication.new(
          subject_patient_dfn: "12345",
          sender_type: "Practitioner",
          sender_id: "101",
          payload_content: "Test"
        )
        fhir = communication.to_fhir

        assert_not_nil fhir[:subject]
        assert_equal "Patient/12345", fhir[:subject][:reference]
      end

      test "to_fhir includes sender reference" do
        communication = Communication.new(
          subject_patient_dfn: "12345",
          sender_type: "Practitioner",
          sender_id: "101",
          payload_content: "Test"
        )
        fhir = communication.to_fhir

        assert_not_nil fhir[:sender]
        assert fhir[:sender][:reference].include?("Practitioner")
      end

      test "to_fhir includes recipient reference" do
        communication = Communication.new(
          subject_patient_dfn: "12345",
          sender_type: "Practitioner",
          sender_id: "101",
          recipient_type: "Patient",
          recipient_id: "12345",
          payload_content: "Test"
        )
        fhir = communication.to_fhir

        assert fhir[:recipient].any?
        assert fhir[:recipient].first[:reference].include?("Patient")
      end

      test "to_fhir includes payload" do
        communication = Communication.new(
          subject_patient_dfn: "12345",
          sender_type: "Practitioner",
          sender_id: "101",
          payload_content: "Important message"
        )
        fhir = communication.to_fhir

        assert fhir[:payload].any?
        assert_equal "Important message", fhir[:payload].first[:contentString]
      end

      test "to_fhir includes sent timestamp" do
        communication = Communication.new(
          subject_patient_dfn: "12345",
          sender_type: "Practitioner",
          sender_id: "101",
          payload_content: "Test",
          sent: DateTime.parse("2024-06-15T10:30:00")
        )
        fhir = communication.to_fhir

        assert_not_nil fhir[:sent]
        assert fhir[:sent].include?("2024-06-15")
      end

      test "to_fhir includes category" do
        communication = Communication.new(
          subject_patient_dfn: "12345",
          sender_type: "Practitioner",
          sender_id: "101",
          payload_content: "Test",
          category: "alert"
        )
        fhir = communication.to_fhir

        assert fhir[:category].any?
        assert_equal "alert", fhir[:category].first[:coding].first[:code]
      end

      test "to_fhir includes priority" do
        communication = Communication.new(
          subject_patient_dfn: "12345",
          sender_type: "Practitioner",
          sender_id: "101",
          payload_content: "Test",
          priority: "urgent"
        )
        fhir = communication.to_fhir

        assert_equal "urgent", fhir[:priority]
      end

      test "resource_class returns Communication" do
        assert_equal "Communication", Communication.resource_class
      end

      test "from_fhir_attributes extracts attributes from OpenStruct" do
        fhir_resource = OpenStruct.new(
          status: "completed",
          subject: OpenStruct.new(reference: "Patient/12345"),
          sender: OpenStruct.new(reference: "Practitioner/101"),
          payload: [ OpenStruct.new(contentString: "Test message") ]
        )

        attrs = Communication.from_fhir_attributes(fhir_resource)
        assert_equal "completed", attrs[:status]
        assert_equal "12345", attrs[:subject_patient_dfn]
        assert_equal "Test message", attrs[:payload_content]
      end

      test "from_fhir creates communication from FHIR resource" do
        fhir_resource = OpenStruct.new(
          status: "completed",
          subject: OpenStruct.new(reference: "Patient/12345"),
          sender: OpenStruct.new(reference: "Practitioner/101"),
          payload: [ OpenStruct.new(contentString: "Test message") ]
        )

        communication = Communication.from_fhir(fhir_resource)
        assert communication.is_a?(Communication)
        assert_equal "completed", communication.status
        assert_equal "12345", communication.subject_patient_dfn
      end

      # =============================================================================
      # EDGE CASE TESTS
      # =============================================================================

      test "handles nil recipient in FHIR" do
        communication = Communication.new(
          subject_patient_dfn: "12345",
          sender_type: "Practitioner",
          sender_id: "101",
          payload_content: "Test",
          recipient_type: nil,
          recipient_id: nil
        )
        fhir = communication.to_fhir

        assert_equal [], fhir[:recipient]
      end

      test "handles nil sent timestamp in FHIR" do
        communication = Communication.new(
          subject_patient_dfn: "12345",
          sender_type: "Practitioner",
          sender_id: "101",
          payload_content: "Test",
          sent: nil
        )
        fhir = communication.to_fhir

        assert_nil fhir[:sent]
      end

      test "handles nil category in FHIR" do
        communication = Communication.new(
          subject_patient_dfn: "12345",
          sender_type: "Practitioner",
          sender_id: "101",
          payload_content: "Test",
          category: nil
        )
        fhir = communication.to_fhir

        assert_equal [], fhir[:category]
      end
    end
  end
end
