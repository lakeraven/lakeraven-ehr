# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/allergy_write_test_helper"

# Gateway write contract for chart allergy entry (#644).
module Lakeraven
  module EHR
    class AllergyIntoleranceGatewayWriteTest < ActiveSupport::TestCase
      include AllergyWriteTestHelper

      DFN = "3"

      setup do
        @attrs = valid_synthetic_allergy_attrs(originator: "1")
        @clinician_duz = DUZ
      end

      def add_with_clinician(attrs = @attrs, clinician_duz: @clinician_duz, **add_kwargs)
        AllergyIntoleranceGateway.add(DFN, attrs, clinician_duz: clinician_duz, **add_kwargs)
      end

      # --- delegation ---------------------------------------------------------

      test "add calls RpmsRpc::Allergy.save with string dfn and allergy hash" do
        fake = FakeAllergyRpc.new(save_returns: { success: true, note_ien: 42 })

        with_fake_allergy_rpc(fake) do
          result = add_with_clinician
          assert gateway_success?(result)
        end

        assert_equal 1, fake.save_calls.length
        assert_equal "3", fake.save_calls.first[:dfn]
        assert_equal @attrs[:agent], fake.save_calls.first[:allergy][:agent]
      end

      test "add succeeds only when rpms-rpc returned success true" do
        fake = FakeAllergyRpc.new(save_returns: { success: true, note_ien: nil })

        with_fake_allergy_rpc(fake) do
          result = add_with_clinician
          assert gateway_success?(result)
        end
      end

      test "record_no_known_allergies calls RpmsRpc::Allergy.no_known_allergies" do
        fake = FakeAllergyRpc.new

        with_fake_allergy_rpc(fake) do
          result = AllergyIntoleranceGateway.record_no_known_allergies(DFN)
          assert gateway_success?(result)
        end

        assert_equal 1, fake.nka_calls.length
        assert_equal "3", fake.nka_calls.first[:dfn]
      end

      test "originator symbol key on attrs is overwritten by clinician_duz on save" do
        fake = FakeAllergyRpc.new
        attrs = valid_synthetic_allergy_attrs(originator: "00001")

        with_fake_allergy_rpc(fake) do
          add_with_clinician(attrs)
        end

        assert_equal DUZ, fake.save_calls.first[:allergy][:originator].to_s
      end

      test "originator string key on attrs is overwritten by clinician_duz on save" do
        fake = FakeAllergyRpc.new
        attrs = valid_synthetic_allergy_attrs.except(:originator)
        attrs["originator"] = "00001"

        with_fake_allergy_rpc(fake) do
          add_with_clinician(attrs)
        end

        assert_equal DUZ, fake.save_calls.first[:allergy][:originator].to_s
      end

      # --- clinician DUZ required ---------------------------------------------

      test "add without clinician_duz returns failure and does not call save" do
        fake = FakeAllergyRpc.new

        with_fake_allergy_rpc(fake) do
          result = nil
          assert_nothing_raised { result = AllergyIntoleranceGateway.add(DFN, @attrs) }
          refute gateway_success?(result)
        end

        assert_empty fake.save_calls
      end

      [
        [ "nil", nil ],
        [ "blank", "" ],
        [ "zero string", "0" ],
        [ "non-integer", "not-a-duz" ]
      ].each do |label, bad_duz|
        test "add with clinician_duz #{label} returns failure and does not call save" do
          fake = FakeAllergyRpc.new

          with_fake_allergy_rpc(fake) do
            result = nil
            assert_nothing_raised { result = add_with_clinician(clinician_duz: bad_duz) }
            refute gateway_success?(result)
          end

          assert_empty fake.save_calls
        end
      end

      # --- fail closed --------------------------------------------------------

      test "add returns failure when rpms-rpc returns success false" do
        fake = FakeAllergyRpc.new(
          save_returns: { success: false, error: :duplicate, message: "duplicate reaction" }
        )

        with_fake_allergy_rpc(fake) do
          result = add_with_clinician
          refute gateway_success?(result)
          refute_includes gateway_failure_reason(result).to_s, SYNTHETIC_AGENT
        end
      end

      [
        [ "nil", nil ],
        [ "string zero", "0" ],
        [ "string success", { success: "true" } ],
        [ "empty hash", {} ]
      ].each do |label, bad|
        test "add returns failure when rpms-rpc save returns #{label}" do
          fake = FakeAllergyRpc.new(save_returns: bad)

          with_fake_allergy_rpc(fake) do
            result = nil
            assert_nothing_raised { result = add_with_clinician }
            refute gateway_success?(result)
          end
        end
      end

      [
        RpmsRpc::Client::RpcError.new("broker failure"),
        RpmsRpc::Client::RpcNotAvailableError.new("rpc missing"),
        RpmsRpc::Client::RpcRefusedError.new("refused")
      ].each do |error|
        test "add returns failure when save raises #{error.class.name}" do
          fake = FakeAllergyRpc.new(save_raise: error)

          with_fake_allergy_rpc(fake) do
            result = nil
            assert_nothing_raised { result = add_with_clinician }
            refute gateway_success?(result)
          end
        end
      end

      test "add returns failure when save raises Encoding::CompatibilityError" do
        fake = FakeAllergyRpc.new(save_raise: Encoding::CompatibilityError.new("incompatible"))

        with_fake_allergy_rpc(fake) do
          result = nil
          assert_nothing_raised { result = add_with_clinician }
          refute gateway_success?(result)
        end
      end

      test "add returns failure when save raises ArgumentError" do
        fake = FakeAllergyRpc.new(save_raise: ArgumentError.new("invalid encoding"))

        with_fake_allergy_rpc(fake) do
          result = nil
          assert_nothing_raised { result = add_with_clinician }
          refute gateway_success?(result)
        end
      end

      test "record_no_known_allergies returns failure when rpc returns success false" do
        fake = FakeAllergyRpc.new(
          nka_returns: { success: false, error: :active_allergies, message: "has active allergies" }
        )

        with_fake_allergy_rpc(fake) do
          result = AllergyIntoleranceGateway.record_no_known_allergies(DFN)
          refute gateway_success?(result)
        end
      end

      test "add does not log allergen text or comments on failure" do
        fake = FakeAllergyRpc.new(
          save_returns: { success: false, error: :duplicate, message: "duplicate reaction" }
        )

        logs = capture_rails_logs do
          with_fake_allergy_rpc(fake) do
            add_with_clinician
          end
        end

        refute_includes logs, SYNTHETIC_AGENT
        refute_includes logs, SYNTHETIC_COMMENT
        refute_includes logs, SYNTHETIC_SYMPTOM
      end
    end
  end
end
