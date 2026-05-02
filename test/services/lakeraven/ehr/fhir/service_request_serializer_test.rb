# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    module FHIR
      class ServiceRequestSerializerTest < ActiveSupport::TestCase
        test "serializes resourceType" do
          result = serialize(build_sr)
          assert_equal "ServiceRequest", result[:resourceType]
        end

        test "includes id" do
          result = serialize(build_sr(ien: 42))
          assert_equal "42", result[:id]
        end

        test "includes status" do
          result = serialize(build_sr(status: "active"))
          assert_equal "active", result[:status]
        end

        test "includes subject patient reference" do
          result = serialize(build_sr(patient_dfn: 123))
          assert_equal "Patient/123", result[:subject][:reference]
        end

        test "includes intent as order" do
          result = serialize(build_sr)
          assert_equal "order", result[:intent]
        end

        test "includes code with service requested" do
          result = serialize(build_sr(service_requested: "Cardiology Consultation"))
          refute_nil result[:code]
          assert_equal "Cardiology Consultation", result[:code][:text]
        end

        test "includes reason for referral" do
          result = serialize(build_sr(reason_for_referral: "Chest pain evaluation"))
          reason = result[:reasonCode]
          refute_nil reason
        end

        test "includes priority" do
          result = serialize(build_sr(urgency: "URGENT"))
          refute_nil result[:priority]
        end

        test "handles missing optional fields" do
          sr = ServiceRequest.new(ien: 1, patient_dfn: 1, status: "draft")
          result = ServiceRequestSerializer.new(sr).to_h
          assert_equal "ServiceRequest", result[:resourceType]
        end

        test "redaction policy applies" do
          policy = RedactionPolicy.new(view: :research)
          result = ServiceRequestSerializer.new(build_sr, policy: policy).to_h
          assert_equal "ServiceRequest", result[:resourceType]
        end

        private

        def build_sr(attrs = {})
          defaults = {
            ien: 42, patient_dfn: 1, status: "active",
            requesting_provider_ien: 101,
            service_requested: "Cardiology Consultation",
            reason_for_referral: "Chest pain evaluation",
            urgency: "ROUTINE"
          }
          ServiceRequest.new(defaults.merge(attrs))
        end

        def serialize(sr)
          ServiceRequestSerializer.new(sr).to_h
        end
      end
    end
  end
end
