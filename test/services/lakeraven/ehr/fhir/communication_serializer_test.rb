# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    module FHIR
      class CommunicationSerializerTest < ActiveSupport::TestCase
        test "serializes resourceType" do
          result = serialize(build_comm)
          assert_equal "Communication", result[:resourceType]
        end

        test "includes status" do
          result = serialize(build_comm(status: "completed"))
          assert_equal "completed", result[:status]
        end

        test "includes subject patient reference" do
          result = serialize(build_comm(subject_patient_dfn: "123"))
          assert_equal "Patient/123", result[:subject][:reference]
        end

        test "includes sender reference" do
          result = serialize(build_comm(sender_type: "Practitioner", sender_id: "101"))
          sender = result[:sender]
          refute_nil sender
          assert_equal "Practitioner/101", sender[:reference]
        end

        test "includes recipient reference" do
          result = serialize(build_comm(recipient_type: "Practitioner", recipient_id: "102"))
          recipients = result[:recipient]
          refute_nil recipients
          assert recipients.any? { |r| r[:reference] == "Practitioner/102" }
        end

        test "includes payload content" do
          result = serialize(build_comm(payload_content: "Lab results are ready"))
          payload = result[:payload]
          refute_nil payload
          assert payload.any? { |p| p[:contentString] == "Lab results are ready" }
        end

        test "includes priority when present" do
          result = serialize(build_comm(priority: "urgent"))
          assert_equal "urgent", result[:priority]
        end

        test "includes category when present" do
          result = serialize(build_comm(category: "notification"))
          refute_nil result[:category]
        end

        test "includes sent timestamp" do
          sent_time = Time.new(2026, 1, 15, 10, 30, 0)
          result = serialize(build_comm(sent: sent_time))
          refute_nil result[:sent]
        end

        test "handles minimal communication" do
          comm = Communication.new(
            subject_patient_dfn: "1",
            sender_id: "101",
            payload_content: "Test"
          )
          result = CommunicationSerializer.new(comm).to_h
          assert_equal "Communication", result[:resourceType]
        end

        test "redaction policy applies" do
          policy = RedactionPolicy.new(view: :research)
          result = CommunicationSerializer.new(build_comm, policy: policy).to_h
          assert_equal "Communication", result[:resourceType]
        end

        private

        def build_comm(attrs = {})
          defaults = {
            ien: "msg-001", subject_patient_dfn: "1", status: "completed",
            sender_type: "Practitioner", sender_id: "101",
            recipient_type: "Practitioner", recipient_id: "102",
            payload_content: "Follow-up appointment scheduled",
            priority: "routine", category: "notification"
          }
          Communication.new(defaults.merge(attrs))
        end

        def serialize(comm)
          CommunicationSerializer.new(comm).to_h
        end
      end
    end
  end
end
