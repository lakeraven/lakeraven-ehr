# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class VfcEligibilityEnforcementServiceTest < ActiveSupport::TestCase
      # =====================================================================
      # VALIDATE -- VFC ENFORCEMENT RULES
      # =====================================================================

      test "VFC lot + VFC-eligible patient (V02) succeeds" do
        with_lot_finder(funding_source: "VFC") do
          with_eligibility_lookup("V02") do
            result = VfcEligibilityEnforcementService.validate(patient_dfn: "1", lot_ien: "10")

            assert result[:success]
          end
        end
      end

      test "VFC lot + VFC-eligible patient (V05) succeeds" do
        with_lot_finder(funding_source: "VFC") do
          with_eligibility_lookup("V05") do
            result = VfcEligibilityEnforcementService.validate(patient_dfn: "1", lot_ien: "10")

            assert result[:success]
          end
        end
      end

      test "VFC lot + non-eligible patient (V01) fails" do
        with_lot_finder(funding_source: "VFC") do
          with_eligibility_lookup("V01") do
            result = VfcEligibilityEnforcementService.validate(patient_dfn: "1", lot_ien: "10")

            assert_not result[:success]
            assert result[:reason].present?
          end
        end
      end

      test "non-VFC lot succeeds for any patient" do
        with_lot_finder(funding_source: "VFA") do
          with_eligibility_lookup("V01") do
            result = VfcEligibilityEnforcementService.validate(patient_dfn: "1", lot_ien: "10")

            assert result[:success]
          end
        end
      end

      test "private lot succeeds for any patient" do
        with_lot_finder(funding_source: "private") do
          with_eligibility_lookup("V01") do
            result = VfcEligibilityEnforcementService.validate(patient_dfn: "1", lot_ien: "10")

            assert result[:success]
          end
        end
      end

      test "missing eligibility fails closed" do
        with_lot_finder(funding_source: "VFC") do
          with_eligibility_lookup(nil) do
            result = VfcEligibilityEnforcementService.validate(patient_dfn: "1", lot_ien: "10")

            assert_not result[:success]
            assert_includes result[:reason].downcase, "eligibility"
          end
        end
      end

      test "missing lot data fails closed" do
        with_lot_finder(returns_nil: true) do
          with_eligibility_lookup("V02") do
            result = VfcEligibilityEnforcementService.validate(patient_dfn: "1", lot_ien: "999")

            assert_not result[:success]
            assert_includes result[:reason].downcase, "lot"
          end
        end
      end

      # =====================================================================
      # VALIDATE -- GATEWAY ERRORS (fail-closed with audit)
      # =====================================================================

      test "lot gateway error fails closed and records audit" do
        with_lot_finder(raises: true) do
          with_eligibility_lookup("V02") do
            count_before = AuditEvent.count
            result = VfcEligibilityEnforcementService.validate(patient_dfn: "1", lot_ien: "10")

            assert_not result[:success]
            assert_includes result[:reason].downcase, "lot"
            assert_equal count_before + 1, AuditEvent.count
          end
        end
      end

      test "eligibility gateway error fails closed and records audit" do
        with_lot_finder(funding_source: "VFC") do
          with_eligibility_lookup(raises: true) do
            count_before = AuditEvent.count
            result = VfcEligibilityEnforcementService.validate(patient_dfn: "1", lot_ien: "10")

            assert_not result[:success]
            assert_includes result[:reason].downcase, "eligibility"
            assert_equal count_before + 1, AuditEvent.count
          end
        end
      end

      # =====================================================================
      # VALIDATE -- DOMAIN RESULT SHAPE
      # =====================================================================

      test "validate returns hash with success and reason keys" do
        with_lot_finder(funding_source: "VFC") do
          with_eligibility_lookup("V02") do
            result = VfcEligibilityEnforcementService.validate(patient_dfn: "1", lot_ien: "10")

            assert_kind_of Hash, result
            assert result.key?(:success)
            assert result.key?(:reason)
          end
        end
      end

      # =====================================================================
      # AUDIT EVENT
      # =====================================================================

      test "validate creates audit event for enforcement decision" do
        with_lot_finder(funding_source: "VFC") do
          with_eligibility_lookup("V02") do
            count_before = AuditEvent.count
            VfcEligibilityEnforcementService.validate(patient_dfn: "1", lot_ien: "10")
            assert_equal count_before + 1, AuditEvent.count
          end
        end
      end

      # =====================================================================
      # ELIGIBLE_LOTS_FOR_PATIENT
      # =====================================================================

      test "eligible_lots_for_patient excludes VFC lots for non-eligible patient" do
        with_lot_lister(all_lots_data) do
          with_eligibility_lookup("V01") do
            lots = VfcEligibilityEnforcementService.eligible_lots_for_patient(
              patient_dfn: "1", vaccine_code: "08"
            )

            vfc_lots = lots.select { |l| l[:funding_source] == "VFC" }
            assert_empty vfc_lots
          end
        end
      end

      test "eligible_lots_for_patient returns VFC lots for eligible patient" do
        with_lot_lister(all_lots_data) do
          with_eligibility_lookup("V02") do
            lots = VfcEligibilityEnforcementService.eligible_lots_for_patient(
              patient_dfn: "1", vaccine_code: "08"
            )

            assert lots.any? { |l| l[:funding_source] == "VFC" }
          end
        end
      end

      test "eligible_lots_for_patient filters by vaccine code" do
        with_lot_lister(all_lots_data) do
          with_eligibility_lookup("V02") do
            lots = VfcEligibilityEnforcementService.eligible_lots_for_patient(
              patient_dfn: "1", vaccine_code: "140"
            )

            lots.each do |lot|
              assert_equal "140", lot[:vaccine_code]
            end
          end
        end
      end

# Through the real gateway, with RPMS stood in for at the gem boundary
# (#583): before, find_lot called a gateway method that did not exist,
# and every check failed closed with "lookup failed: NoMethodError".
test "validate reads the lot through the gateway: a VFC lot and an eligible patient pass" do
  vfc_lot = { ien: 10, lot_number: "VFC-123", active: true, vaccine_ien: 4, vaccine: "MMR", cvx: "03",
              expiration_date: Date.new(2027, 1, 31), source: "v", source_label: "VFC" }
  with_stub(RpmsRpc::ImmunizationLot, :find, vfc_lot) do
    with_eligibility_lookup("V04") do
      result = VfcEligibilityEnforcementService.validate(patient_dfn: "1", lot_ien: "10")

      assert result[:success], result[:reason]
    end
  end
end

test "eligible_lots_for_patient lists lots through the gateway" do
  lots = [ { ien: 10, lot_number: "VFC-123", active: true, cvx: "03", source: "v", source_label: "VFC" },
           { ien: 11, lot_number: "PVT-9", active: true, cvx: "03", source: "n", source_label: "NON-VFC" } ]
  with_stub(RpmsRpc::ImmunizationLot, :list, lots) do
    with_eligibility_lookup("V01") do
      listed = VfcEligibilityEnforcementService.eligible_lots_for_patient(patient_dfn: "1", vaccine_code: "03")

      assert_equal %w[PVT-9], listed.map { |l| l[:lot_number] }, "a patient not VFC-eligible is offered only non-VFC lots"
    end
  end
end

      private

      def with_lot_finder(funding_source: nil, returns_nil: false, raises: false)
        orig = VfcEligibilityEnforcementService.method(:find_lot)
        if raises
          VfcEligibilityEnforcementService.define_singleton_method(:find_lot) do |_ien|
            raise StandardError, "Connection refused"
          end
        elsif returns_nil
          VfcEligibilityEnforcementService.define_singleton_method(:find_lot) { |_ien| nil }
        else
          VfcEligibilityEnforcementService.define_singleton_method(:find_lot) do |_ien|
            { ien: "10", lot_number: "LOT123", vaccine_code: "08",
              vaccine_display: "COVID-19", manufacturer: "Pfizer",
              funding_source: funding_source, status: "Active" }
          end
        end
        yield
      ensure
        VfcEligibilityEnforcementService.define_singleton_method(:find_lot, orig)
      end

      def with_eligibility_lookup(code = nil, raises: false)
        orig = VfcEligibilityEnforcementService.method(:patient_eligibility)
        if raises
          VfcEligibilityEnforcementService.define_singleton_method(:patient_eligibility) do |_dfn|
            raise StandardError, "Timeout"
          end
        else
          VfcEligibilityEnforcementService.define_singleton_method(:patient_eligibility) do |_dfn|
            { code: code, label: code.present? ? "Eligibility #{code}" : nil }
          end
        end
        yield
      ensure
        VfcEligibilityEnforcementService.define_singleton_method(:patient_eligibility, orig)
      end

      def with_lot_lister(data)
        orig = VfcEligibilityEnforcementService.method(:list_lots)
        VfcEligibilityEnforcementService.define_singleton_method(:list_lots) { data }
        yield
      ensure
        VfcEligibilityEnforcementService.define_singleton_method(:list_lots, orig)
      end

      def all_lots_data
        [
          { ien: "1", lot_number: "LOT-VFC", vaccine_code: "08",
            vaccine_display: "COVID-19", manufacturer: "Pfizer",
            funding_source: "VFC", status: "Active" },
          { ien: "2", lot_number: "LOT-VFA", vaccine_code: "08",
            vaccine_display: "COVID-19", manufacturer: "Pfizer",
            funding_source: "VFA", status: "Active" },
          { ien: "3", lot_number: "LOT-FLU", vaccine_code: "140",
            vaccine_display: "Influenza", manufacturer: "Sanofi",
            funding_source: "VFC", status: "Active" }
        ]
      end
    end
  end
end
