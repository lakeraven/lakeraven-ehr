# frozen_string_literal: true

require "test_helper"

# Tests for ConditionGateway — engine wrapper around RpmsRpc::Problem.
# Engine vocabulary is "Condition" (matches app/models/lakeraven/ehr/condition.rb);
# rpms-rpc vocabulary is "Problem".
module Lakeraven
  module EHR
    class ConditionGatewayTest < ActiveSupport::TestCase
      # --- read: for_patient ---

      test "for_patient returns the seeded problem list" do
        RpmsRpc.client.seed_keyed_collection(:problem_list, "1", [
          { icd_code: "E11.9", description: "Type 2 diabetes", status: "A" }
        ])

        result = ConditionGateway.for_patient(1)

        assert_kind_of Array, result
        assert_equal "E11.9", result.first[:icd_code]
      end

      # --- write: add / update / delete ---

      test "add returns success with the saved IEN" do
        # rpms-rpc 0.3.0: Problem.add/update write via :problem_set (was :problem_edit).
        RpmsRpc.client.seed_scalar(:problem_set, "1", "55")

        result = ConditionGateway.add(1, { icd_code: "E11.9", description: "Type 2 diabetes" })

        assert result[:success]
        assert_equal 55, result[:ien]
      end

      test "update returns success with the saved IEN" do
        RpmsRpc.client.seed_scalar(:problem_set, "1", "55")

        result = ConditionGateway.update(1, 55, { status: "I" })

        assert result[:success]
        assert_equal 55, result[:ien]
      end

      test "delete issues BGOPROB DEL with the IEN and reason, and returns success" do
        # 0.3.0: delete calls DEL^BGOPROB (:problem_remove), whose success
        # reply is "" — the same value the mock returns for ANY unseeded RPC.
        # Asserting result[:success] alone is therefore vacuous (a regression
        # to another RPC, or to no RPC at all, would ride the default green),
        # so pin the recorded wire call: name and IEN^TYPE^REASON param.
        result = ConditionGateway.delete(1, 55, reason: "Entered in error")

        assert result[:success]
        assert_equal 55, result[:ien]
        call = RpmsRpc.client.received_calls.last
        assert_equal "BGOPROB DEL", call[:rpc]
        assert_equal [ "55^^Entered in error" ], call[:params]
      end

      test "delete surfaces a server error reply as failure" do
        # The mock CAN express this failure: an error reply is "-CODE^text",
        # keyed (like every scalar seed) by the RPC's first param. The mock is
        # process-global, so this seed uses its own IEN/reason key to avoid
        # bleeding into the success-path test in other run orders.
        RpmsRpc.client.seed_scalar(:problem_remove, "66^^Wrong patient", "-1^Cannot delete")

        result = ConditionGateway.delete(1, 66, reason: "Wrong patient")

        refute result[:success]
        assert_nil result[:ien]
      end

      test "add returns failure for invalid dfn" do
        result = ConditionGateway.add(nil, { icd_code: "E11.9" })

        refute result[:success]
      end

      test "add does not write an F10-F19 code to the shared problem list" do
        before = RpmsRpc.client.received_calls.length

        result = ConditionGateway.add("123", {
          code: "F11.20",
          display: "Opioid dependence",
          code_system: "http://hl7.org/fhir/sid/icd-10-cm"
        })

        refute result[:success]
        assert_nil result[:ien]
        assert_match(/F10-F19/, result[:error])
        assert_match(/no per-record sensitivity flag/, result[:error])
        assert_match(/no Part 2 store/, result[:error])
        assert_equal before, RpmsRpc.client.received_calls.length
      end

      test "add refuses a problem it cannot classify" do
        before = RpmsRpc.client.received_calls.length

        result = ConditionGateway.add(1, { description: "Opioid dependence" })

        refute result[:success]
        assert_match(/could not be classified/, result[:error])
        assert_equal before, RpmsRpc.client.received_calls.length
      end

      test "add still writes an ICD-10-CM code outside F10-F19" do
        RpmsRpc.client.seed_scalar(:problem_set, "8", "56")

        result = ConditionGateway.add(8, { icd_code: "F32.1", description: "Major depressive disorder" })

        assert result[:success]
        assert_equal 56, result[:ien]
      end

      test "update does not write an F10-F19 code onto the shared problem list" do
        before = RpmsRpc.client.received_calls.length

        result = ConditionGateway.update(1, 55, { icd_code: "F11.20" })

        refute result[:success]
        assert_match(/F10-F19/, result[:error])
        assert_equal before, RpmsRpc.client.received_calls.length
      end

      # --- filter ---

      test "filter returns the seeded list scoped by IPL tab" do
        RpmsRpc.client.seed_keyed_collection(:problem_filter, "1", [
          { icd_code: "I10", description: "Essential hypertension", status: "A" }
        ])

        result = ConditionGateway.filter(1, scope: :core)

        assert_kind_of Array, result
        assert_equal "I10", result.first[:icd_code]
      end

      test "filter raises for unknown scope" do
        assert_raises(ArgumentError) { ConditionGateway.filter(1, scope: :unknown_scope) }
      end

      test "filter returns empty for invalid dfn" do
        assert_equal [], ConditionGateway.filter(nil, scope: :core)
      end
      # --- Gate findings on #568 (OpenAI/Sol), each reproduced then closed ---
      #
      # These are regression tests for three ways a substance-use diagnosis
      # reached the shared RPMS problem list despite the #560 write block.
      # That file has no per-record sensitivity flag (ADR 0006), so each of
      # these was an irreversible write.

      # Z71.41 is a VALID ICD-10-CM code outside F10-F19, so the range check
      # called it :not_sud and wrote it. Codes verified against the ICD-10-CM
      # FY2026 set, not guessed.
      test "a substance-use counseling code outside F10-F19 is refused" do
        [ "Z71.4", "Z71.41", "Z71.42", "Z71.5", "Z71.51", "Z71.52" ].each do |code|
          calls = capture_problem_calls(:add) do
            ConditionGateway.add("1", { code: code, display: "counseling" })
          end
          assert_empty calls, "#{code} reached the shared RPMS problem list"
        end
      end

      # F55 is abuse of NON-psychoactive substances (antacids, laxatives,
      # vitamins). Not alcohol or drug abuse, so not a Part 2 record, so it
      # must still be writable -- the block has to be narrow as well as closed.
      test "abuse of non-psychoactive substances is still written" do
        calls = capture_problem_calls(:add) do
          ConditionGateway.add("1", { code: "F55.2", display: "Abuse of laxatives" })
        end
        refute_empty calls, "F55.2 is not a Part 2 record and must not be refused"
      end

      # The classifier stopped at the first code-bearing key it found, so a
      # safe-looking :code shadowed an F10-F19 :icd_code. Precedence between
      # fields is not a safety property.
      test "an F10-F19 code in icd_code is refused even when code looks safe" do
        calls = capture_problem_calls(:add) do
          ConditionGateway.add("1", { code: "E11.9", icd_code: "F11.20", display: "diabetes" })
        end
        assert_empty calls, "a shadowed F11.20 reached the shared RPMS problem list"
      end

      # An update with no code was waved through unclassified. This gateway
      # cannot re-read the stored row, so it cannot know what is being
      # amended -- and absence of a code is not evidence the change is safe.
      test "an update rewriting clinical text with no code is refused" do
        calls = capture_problem_calls(:update) do
          ConditionGateway.update("1", 55, { display: "Opioid use disorder" })
        end
        assert_empty calls, "an uncoded narrative update reached the shared RPMS problem list"
      end

      # The block must stay NARROW. Refusing every uncoded update broke
      # marking a problem inactive, which carries no diagnosis at all.
      # Over-blocking a legitimate administrative write is its own defect.
      test "an administrative-only update is still written" do
        calls = capture_problem_calls(:update) do
          ConditionGateway.update("1", 55, { status: "I" })
        end
        refute_empty calls, "a status-only update must not be refused"
      end

      private

      def capture_problem_calls(method_name)
        calls = []
        original = RpmsRpc::Problem.method(method_name)
        RpmsRpc::Problem.define_singleton_method(method_name) do |*args, **kwargs|
          calls << { args: args, kwargs: kwargs }
          "1^^1"
        end
        yield
        calls
      ensure
        RpmsRpc::Problem.define_singleton_method(method_name, original)
      end
    end
  end
end
