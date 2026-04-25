# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class CpoeOrderTest < ActiveSupport::TestCase
      # ======================================================================
      # SIGNING - CONTENT HASH
      # ======================================================================

      test "sign! captures SHA-256 content hash" do
        order = build_lab_order
        order.sign!(provider_duz: "789")

        assert order.signed_content_hash.present?
        assert_match(/\A[a-f0-9]{64}\z/, order.signed_content_hash)
      end

      test "content hash matches order content after signing" do
        order = build_lab_order
        order.sign!(provider_duz: "789")

        assert order.content_hash_valid?
      end

      test "content_hash_valid? detects hash mismatch" do
        order = build_lab_order
        order.sign!(provider_duz: "789")
        assert order.content_hash_valid?

        expected = order.compute_content_hash
        assert_equal expected, order.signed_content_hash

        order2 = build_lab_order(test_name: "Different Test")
        different_hash = order2.compute_content_hash
        assert_not_equal different_hash, order.signed_content_hash
      end

      test "different orders produce different content hashes" do
        order1 = build_lab_order(test_name: "CBC")
        order1.sign!(provider_duz: "789")

        order2 = build_lab_order(test_name: "BMP")
        order2.sign!(provider_duz: "789")

        assert_not_equal order1.signed_content_hash, order2.signed_content_hash
      end

      test "content hash includes imaging-specific fields" do
        order1 = build_imaging_order(body_site: "Chest", laterality: "bilateral")
        order1.sign!(provider_duz: "789")

        order2 = build_imaging_order(body_site: "Chest", laterality: "left")
        order2.sign!(provider_duz: "789")

        assert_not_equal order1.signed_content_hash, order2.signed_content_hash
      end

      # ======================================================================
      # SIGNING - SIGNER IDENTITY AND TIMESTAMP
      # ======================================================================

      test "sign! records signer identity" do
        order = build_lab_order
        order.sign!(provider_duz: "789")

        assert_equal "789", order.signer_duz
      end

      test "sign! records signing timestamp" do
        order = build_lab_order
        freeze_time do
          order.sign!(provider_duz: "789")
          assert_equal Time.current, order.signed_at
        end
      end

      test "sign! sets status to active and intent to order" do
        order = build_lab_order
        order.sign!(provider_duz: "789")

        assert_equal "active", order.status
        assert_equal "order", order.intent
      end

      # ======================================================================
      # SIGNING - DOUBLE-SIGN PREVENTION
      # ======================================================================

      test "sign! raises on already-signed order" do
        order = build_lab_order
        order.sign!(provider_duz: "789")

        error = assert_raises(CpoeOrder::OrderAlreadySignedError) do
          order.sign!(provider_duz: "999")
        end
        assert_equal "Order has already been signed", error.message
      end

      # ======================================================================
      # IMMUTABILITY - SIGNED ORDER ATTRIBUTES
      # ======================================================================

      test "signed order rejects modification of patient_dfn" do
        order = build_and_sign
        assert_raises(CpoeOrder::OrderAlreadySignedError) { order.patient_dfn = "99999" }
      end

      test "signed order rejects modification of category" do
        order = build_and_sign
        assert_raises(CpoeOrder::OrderAlreadySignedError) { order.category = "imaging" }
      end

      test "signed order rejects modification of code" do
        order = build_and_sign
        assert_raises(CpoeOrder::OrderAlreadySignedError) { order.code = "99999-9" }
      end

      test "signed order rejects modification of code_display" do
        order = build_and_sign
        assert_raises(CpoeOrder::OrderAlreadySignedError) { order.code_display = "Tampered Test" }
      end

      test "signed order rejects modification of clinical_reason" do
        order = build_and_sign
        assert_raises(CpoeOrder::OrderAlreadySignedError) { order.clinical_reason = "Changed reason" }
      end

      test "signed order rejects modification of priority" do
        order = build_and_sign
        assert_raises(CpoeOrder::OrderAlreadySignedError) { order.priority = "stat" }
      end

      test "signed imaging order rejects modification of body_site" do
        order = build_imaging_order
        order.sign!(provider_duz: "789")
        assert_raises(CpoeOrder::OrderAlreadySignedError) { order.body_site = "Abdomen" }
      end

      test "signed imaging order rejects modification of laterality" do
        order = build_imaging_order
        order.sign!(provider_duz: "789")
        assert_raises(CpoeOrder::OrderAlreadySignedError) { order.laterality = "right" }
      end

      # ======================================================================
      # IMMUTABILITY - SIGNATURE METADATA
      # ======================================================================

      test "signed order rejects modification of signed_content_hash" do
        order = build_and_sign
        assert_raises(CpoeOrder::OrderAlreadySignedError) { order.signed_content_hash = "tampered" }
      end

      test "signed order rejects modification of signer_duz" do
        order = build_and_sign
        assert_raises(CpoeOrder::OrderAlreadySignedError) { order.signer_duz = "999" }
      end

      test "signed order rejects modification of signed_at" do
        order = build_and_sign
        assert_raises(CpoeOrder::OrderAlreadySignedError) { order.signed_at = Time.current + 1.hour }
      end

      test "signed order allows setting same value (no-op)" do
        order = build_and_sign
        assert_nothing_raised do
          order.patient_dfn = order.patient_dfn
          order.code_display = order.code_display
        end
      end

      test "signed order still allows status change for cancellation" do
        order = build_and_sign
        assert_nothing_raised { order.cancel! }
        assert_equal "cancelled", order.status
      end

      test "unsigned order allows free modification" do
        order = build_lab_order
        assert_nothing_raised do
          order.patient_dfn = "99999"
          order.code_display = "Changed Test"
          order.priority = "stat"
        end
      end

      # ======================================================================
      # SIGNED? PREDICATE
      # ======================================================================

      test "signed? returns false for unsigned order" do
        assert_not build_lab_order.signed?
      end

      test "signed? returns true after signing" do
        order = build_lab_order
        order.sign!(provider_duz: "789")
        assert order.signed?
      end

      # ======================================================================
      # DEFAULTS AND PREDICATES
      # ======================================================================

      test "defaults to draft status" do
        order = CpoeOrder.new(code_display: "CBC", patient_dfn: "1")
        assert order.draft?
        refute order.signed?
      end

      # ======================================================================
      # FHIR SERIALIZATION
      # ======================================================================

      test "to_fhir returns ServiceRequest resource" do
        order = CpoeOrder.new(id: "ord-1", patient_dfn: "1", code_display: "CBC", status: "active", intent: "order")
        fhir = order.to_fhir
        assert_equal "ServiceRequest", fhir[:resourceType]
        assert_equal "active", fhir[:status]
      end

      private

      def build_lab_order(test_name: "Complete Blood Count", test_code: "58410-2")
        CpoeOrder.new(
          id: "cpoe-#{SecureRandom.hex(8)}",
          patient_dfn: "12345",
          requester_duz: "789",
          status: "draft",
          intent: "plan",
          category: "laboratory",
          priority: "routine",
          code: test_code,
          code_display: test_name,
          clinical_reason: "Annual screening",
          authored_on: Time.current
        )
      end

      def build_imaging_order(body_site: "Chest", laterality: "bilateral")
        CpoeOrder.new(
          id: "cpoe-#{SecureRandom.hex(8)}",
          patient_dfn: "12345",
          requester_duz: "789",
          status: "draft",
          intent: "plan",
          category: "imaging",
          priority: "routine",
          code_display: "Chest X-Ray",
          body_site: body_site,
          laterality: laterality,
          clinical_reason: "Rule out pneumonia",
          authored_on: Time.current
        )
      end

      def build_and_sign
        order = build_lab_order
        order.sign!(provider_duz: "789")
        order
      end
    end
  end
end
