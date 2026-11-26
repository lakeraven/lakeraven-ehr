# frozen_string_literal: true

require "test_helper"

# ProblemEntryGateway's own logic: what it sends for a concept, that nothing
# is called filed until RPMS reads it back, and what each refusal or failure
# answers. The stand-in answers the rpms-rpc methods with the facts they
# returned on the pinned demo image for SNOMED CT 370143000 (major
# depressive disorder, F32.9). That RPMS files and reads them back is proven
# live: features/problem_list/add_diagnosis_as_problem.feature.
module Lakeraven
  module EHR
    class ProblemEntryGatewayTest < ActiveSupport::TestCase
      DFN = "990022"
      VISIT = "122"
      CONCEPT = "370143000"
      NEW_ENTRY = {
        ien: 0, snomed_ct: CONCEPT, laterality: nil, description_id: "1195435015", narrative: "Major depressive disorder",
        exact: true, laterality_text: nil, icd_codes: [ "F32.9" ], status: nil, default_status: nil,
        prompts_laterality: false, lateralized: false
      }.freeze
      ON_FILE = NEW_ENTRY.merge(ien: 148, description_id: nil, narrative: "*Major depressive disorder", status: "E", icd_codes: []).freeze
      FILED = {
        ien: 148, snomed_concept: CONCEPT, snomed_description: "1195435015", number: "DIC-3", status: "EPISODIC",
        narrative: "*Major depressive disorder", icd_code: "F32.9", additional_icd: nil, laterality: nil
      }.freeze
      POV = {
        ien: 206, icd_code: "F32.9", narrative: "*Major depressive disorder", primary_or_secondary: "PRIMARY",
        visit_ien: 122, problem_ien: "148", icd_name: "Major depressive disorder, single episode, unspecified"
      }.freeze

      setup do
        @original_client = RpmsRpc.configuration.client
        RpmsStandIn.install!
        RpmsStandIn.answer(ProblemEntryGateway, :location_ien, with: "7819")
        RpmsStandIn.answer(RpmsRpc::Problem, :duplicate_check, with: { on_file: [], new_entry: NEW_ENTRY })
        RpmsStandIn.answer(RpmsRpc::Problem, :add, with: { success: true, ien: 148, raw: "148" })
        RpmsStandIn.answer(RpmsRpc::Problem, :integrated, with: [ FILED ])
        RpmsStandIn.answer(RpmsRpc::Pov, :add, with: { success: true, ien: 206, raw: "206" })
        RpmsStandIn.answer(RpmsRpc::Pov, :for_visit, with: [ POV, POV.merge(ien: 205, problem_ien: "9") ])
      end

      teardown do
        RpmsStandIn.reset!
        RpmsRpc.configure { |c| c.client = @original_client }
      end

      def add(**options) = ProblemEntryGateway.add(DFN, concept_id: CONCEPT, status: "Episodic", **options)

      test "S-VIS-02.2 files the concept as BSTS maps it, then the purpose of visit against the new problem, and answers both as read back" do
        result = add(visit_ien: VISIT, provider_duz: "206")

        assert_equal :filed, result.outcome
        assert_equal FILED, result.problem
        assert_equal [ POV ], result.diagnoses, "only the visit's diagnoses filed against this problem"
        assert_equal [ [ DFN, { snomed_ct: CONCEPT, descriptive_ct: "1195435015", icd_code: "F32.9", description: "Major depressive disorder",
                                location_ien: "7819", status: "Episodic", laterality: nil } ] ],
                     RpmsStandIn.calls(RpmsRpc::Problem, :add).map { |c| c[:args] }
        pov = RpmsStandIn.calls(RpmsRpc::Pov, :add).sole
        assert_equal [ DFN, VISIT, "F32.9" ], pov[:args]
        assert_equal({ problem_ien: 148, snomed_ct: CONCEPT, descriptive_ct: "1195435015", provider_duz: "206" }, pov[:kwargs][:modifiers])
      end

      test "S-VIS-02.3 without a visit only the problem is filed" do
        result = add

        assert_equal :filed, result.outcome
        assert_empty result.diagnoses
        assert_empty RpmsStandIn.calls(RpmsRpc::Pov, :add)
      end

      test "the side is checked and filed by its name" do
        add(laterality: "Left")

        assert_equal "Left", RpmsStandIn.calls(RpmsRpc::Problem, :duplicate_check).sole[:kwargs][:laterality]
        assert_equal "Left", RpmsStandIn.calls(RpmsRpc::Problem, :add).sole[:args].last[:laterality]
      end

      test "a concept on the list already is answered with the problems that hold it, and nothing is sent" do
        RpmsStandIn.answer(RpmsRpc::Problem, :duplicate_check, with: { on_file: [ ON_FILE ], new_entry: nil })

        result = add(visit_ien: VISIT)

        assert_equal :duplicate, result.outcome
        assert_equal [ ON_FILE ], result.on_file
        assert_empty RpmsStandIn.calls(RpmsRpc::Problem, :add)
      end

      test "a substance use diagnosis is refused by the shared list's rule, and nothing is sent" do
        RpmsStandIn.answer(RpmsRpc::Problem, :duplicate_check, with: { on_file: [], new_entry: NEW_ENTRY.merge(icd_codes: [ "F10.20" ]) })

        result = add(visit_ien: VISIT)

        assert_equal :refused, result.outcome
        assert_includes result.reason, "F10-F19"
        assert_empty RpmsStandIn.calls(RpmsRpc::Problem, :add)
      end

      test "a concept BSTS maps no code to is refused before anything is sent" do
        RpmsStandIn.answer(RpmsRpc::Problem, :duplicate_check, with: { on_file: [], new_entry: NEW_ENTRY.merge(icd_codes: []) })

        assert_equal :refused, add.outcome
        assert_empty RpmsStandIn.calls(RpmsRpc::Problem, :add)
      end

      test "a session with no division files nothing" do
        RpmsStandIn.answer(ProblemEntryGateway, :location_ien, with: nil)

        assert_equal :refused, add.outcome
        assert_empty RpmsStandIn.calls(RpmsRpc::Problem, :add)
      end

      test "RPMS refusing the problem answers its own reason" do
        RpmsStandIn.answer(RpmsRpc::Problem, :add, with: { success: false, ien: nil, raw: "-1048^Invalid ICD code" })

        result = add(visit_ien: VISIT)

        assert_equal :refused, result.outcome
        assert_equal "Invalid ICD code", result.reason
        assert_empty RpmsStandIn.calls(RpmsRpc::Pov, :add)
      end

      test "RPMS refusing this user the RPC is forbidden, with RPMS's reason" do
        refusal = RpmsRpc::Client::RpcRefusedError.new("BGOPROB2 DUPCHK is not in your menu")
        RpmsStandIn.answer(RpmsRpc::Problem, :duplicate_check) { raise refusal }

        result = add

        assert_equal :forbidden, result.outcome
        assert_includes result.reason, "not in your menu"
        assert_empty RpmsStandIn.calls(RpmsRpc::Problem, :add)
      end

      test "a problem the list does not show after the write is unknown, not filed" do
        RpmsStandIn.answer(RpmsRpc::Problem, :integrated, with: [])

        result = add(visit_ien: VISIT)

        assert_equal :unknown, result.outcome
        refute result.problem_filed?
        assert_empty RpmsStandIn.calls(RpmsRpc::Pov, :add)
      end

      test "a connection lost during the problem write is unknown" do
        RpmsStandIn.answer(RpmsRpc::Problem, :add) { raise IOError, "closed" }

        assert_equal :unknown, add.outcome
      end

      test "RPMS refusing the purpose of visit leaves the problem filed, with RPMS's reason" do
        RpmsStandIn.answer(RpmsRpc::Pov, :add, with: { success: false, ien: nil, raw: "-1003^Visit is locked" })

        result = add(visit_ien: VISIT)

        assert_equal :problem_only, result.outcome
        assert result.problem_filed?
        assert_equal "Visit is locked", result.reason
      end

      test "a purpose of visit the visit does not show after the write is unknown" do
        RpmsStandIn.answer(RpmsRpc::Pov, :for_visit, with: [ POV.merge(problem_ien: "9") ])

        result = add(visit_ien: VISIT)

        assert_equal :pov_unknown, result.outcome
        assert result.problem_filed?
      end

      test "a stored laterality pair reads as its side" do
        assert_equal "Left", ProblemEntryGateway.side("272741003|7771000")
        assert_equal "272741003|99", ProblemEntryGateway.side("272741003|99")
      end
    end
  end
end
