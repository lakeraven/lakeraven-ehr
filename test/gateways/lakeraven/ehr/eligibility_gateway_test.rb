# frozen_string_literal: true

require "test_helper"

# Tests for EligibilityGateway — VFC eligibility via BIPC ELIGGET / BIPC ELIGLIST.
# Uses mock data seeded in test_helper.rb via RpmsRpc.mock!
module Lakeraven
  module EHR
    class EligibilityGatewayTest < ActiveSupport::TestCase
      # === patient_eligibility ===

      test "patient_eligibility returns hash with code and label" do
        result = EligibilityGateway.patient_eligibility("1")

        assert_kind_of Hash, result
        assert result.key?(:code), "Should have :code key"
        assert result.key?(:label), "Should have :label key"
      end

      test "patient_eligibility returns seeded VFC code for patient 1" do
        result = EligibilityGateway.patient_eligibility("1")

        # BGOVIMM GETVFC answers a label; it resolves to the GETELIG row that
        # carries it (rpms-rpc #376).
        assert_equal "V04", result[:code]
        assert_equal "Am Indian/AK Native", result[:label]
      end

      test "patient_eligibility returns nil code for unknown patient" do
        result = EligibilityGateway.patient_eligibility("999999")

        assert_nil result[:code], "Should return nil code for unknown patient"
      end

      # === list_codes ===

      test "list_codes returns array of hashes" do
        codes = EligibilityGateway.list_codes

        assert_kind_of Array, codes
        assert codes.length > 0, "Should return seeded VFC codes"
      end

      test "list_codes returns all seeded VFC codes" do
        codes = EligibilityGateway.list_codes

        assert_equal 7, codes.length, "Should return all 7 seeded VFC codes"
      end

      test "list_codes entries have code and label keys" do
        codes = EligibilityGateway.list_codes

        codes.each do |entry|
          assert_kind_of Hash, entry
          assert entry.key?(:code), "Entry should have :code"
          assert entry.key?(:label), "Entry should have :label"
        end
      end

      test "list_codes includes expected codes" do
        codes = EligibilityGateway.list_codes
        code_values = codes.map { |c| c[:code] }

        assert_includes code_values, "V01"
        assert_includes code_values, "V04"
        assert_includes code_values, "V07"
      end

      test "list_codes first entry is V01" do
        codes = EligibilityGateway.list_codes

        assert_equal "V01", codes.first[:code]
        assert_equal "Not VFC eligible", codes.first[:label]
      end

      test "list_codes AI/AN entry has correct label" do
        codes = EligibilityGateway.list_codes
        ai_an = codes.find { |c| c[:code] == "V04" }

        assert_not_nil ai_an
        assert_equal "Am Indian/AK Native", ai_an[:label]
      end
# === vaccine lots, for the VFC check (#583) ===
#
# RpmsRpc::ImmunizationLot's shape: source is VACCINE SOURCE's internal
# code ("v" is VFC), cvx the vaccine's HL7-CVX CODE.
class LotSource
  LOTS = {
    10 => { ien: 10, lot_number: "VFC-123", active: true, vaccine_ien: 4, vaccine: "MMR", cvx: "03",
            expiration_date: Date.new(2027, 1, 31), source: "v", source_label: "VFC" },
    11 => { ien: 11, lot_number: "PVT-9", active: true, vaccine_ien: 4, vaccine: "MMR", cvx: "03",
            expiration_date: Date.new(2027, 1, 31), source: "n", source_label: "NON-VFC" }
  }.freeze

  def self.find(ien) = LOTS[ien.to_i]
  def self.list = LOTS.values
end

class NoAnswer
  def self.list = nil
end

test "find_lot reads the lot's VFC source and CVX code" do
  lot = EligibilityGateway.find_lot("10", via: LotSource)

  assert_equal "VFC", lot[:funding_source]
  assert_equal "03", lot[:vaccine_code]
  assert_equal "VFC-123", lot[:lot_number]
end

test "a lot from another source is not VFC" do
  assert_equal "NON-VFC", EligibilityGateway.find_lot("11", via: LotSource)[:funding_source]
end

test "an unknown lot is nil" do
  assert_nil EligibilityGateway.find_lot("999", via: LotSource)
end

test "list_lots lists every lot in the same shape" do
  assert_equal %w[VFC NON-VFC], EligibilityGateway.list_lots(via: LotSource).map { |l| l[:funding_source] }
end

test "list_lots raises when RPMS gives no answer, rather than reading as no lots" do
  assert_raises(RpmsRpc::Client::RpcError) { EligibilityGateway.list_lots(via: NoAnswer) }
end

    end
  end
end
