# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class CpoeOrderTest < ActiveSupport::TestCase
      test "defaults to draft status" do
        order = CpoeOrder.new(code_display: "CBC", patient_dfn: "1")
        assert order.draft?
        refute order.signed?
      end

      test "sign! sets signed_at and status to active" do
        order = CpoeOrder.new(code_display: "CBC", patient_dfn: "1")
        order.sign!(signer_duz: "101")

        assert order.signed?
        assert order.active?
        assert_equal "101", order.signer_duz
        assert order.signed_content_hash.present?
      end

      test "to_fhir returns ServiceRequest resource" do
        order = CpoeOrder.new(id: "ord-1", patient_dfn: "1", code_display: "CBC", status: "active", intent: "order")
        fhir = order.to_fhir
        assert_equal "ServiceRequest", fhir[:resourceType]
        assert_equal "active", fhir[:status]
      end
    end
  end
end
