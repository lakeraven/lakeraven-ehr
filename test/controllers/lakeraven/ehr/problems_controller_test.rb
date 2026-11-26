# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/patient_banner_test_helper"

module Lakeraven
  module EHR
    # A provider adds the diagnosis Find a diagnosis showed as a problem, and
    # as today's purpose of visit (rpms-ux S-VIS-02.2, S-VIS-02.3). The
    # gateways stand in for RPMS here, answering what they answered on the
    # pinned demo image; features/problem_list/add_diagnosis_as_problem.feature
    # files both on a real RPMS and reads them back.
    class ProblemsControllerTest < ActionDispatch::IntegrationTest
      include PatientBannerTestHelper

      DFN = "3"
      BASE = "#{MOUNT}/patients/#{DFN}/problems".freeze
      PROVIDER = %w[provider orders_sign].freeze
      DEPRESSION = {
        term: "Major depressive disorder", preferred_term: "Major depressive disorder", concept_id: "370143000", dts_id: "370143",
        fsn: "Major depressive disorder (disorder)", icd: [ "F32.9" ], prompt_laterality: false, default_status: nil,
        requires_episodicity: false, prompt_abnormal_finding: false, selectable: true
      }.freeze
      OTITIS = DEPRESSION.merge(preferred_term: "Otitis media", concept_id: "65363002", dts_id: "65363", icd: [ "H66.90" ],
                                prompt_laterality: true).freeze
      STORED = {
        ien: 148, snomed_concept: "370143000", number: "DIC-3", status: "EPISODIC", narrative: "*Major depressive disorder",
        icd_code: "F32.9", additional_icd: nil, laterality: nil
      }.freeze
      POV = { ien: 206, icd_code: "F32.9", narrative: "*Major depressive disorder", primary_or_secondary: "PRIMARY",
              visit_ien: 501, problem_ien: "148", icd_name: "Major depressive disorder, single episode, unspecified" }.freeze

      setup do
        enable_forgery_protection!
        @original_client = RpmsRpc.configuration.client
        RpmsStandIn.install! { |rpms| LakeravenDemoSeeds.seed(rpms) }
        now = SiteTime.now
        @today = { visit_ien: 501, location: "SYNTHETIC CLINIC A", datetime: Time.utc(now.year, now.month, now.day, 0, 1), locked: false }
        @yesterday = @today.merge(visit_ien: 400, datetime: @today[:datetime] - 86_400)
        answer_visits([ @today, @yesterday ])
        RpmsStandIn.answer(TerminologyGateway, :concept, with: DEPRESSION)
        RpmsStandIn.answer(ProblemEntryGateway, :check, with: { on_file: [], new_entry: {} })
        RpmsStandIn.answer(ProblemEntryGateway, :problem, with: STORED)
        RpmsStandIn.answer(ProblemEntryGateway, :diagnoses, with: [ POV ])
      end

      teardown do
        restore_forgery_protection!
        teardown_oauth!
        RpmsStandIn.reset!
        RpmsRpc.configure { |c| c.client = @original_client }
      end

      test "S-VIS-02.2 the provider adds the diagnosis as a problem and today's purpose of visit, and sees what RPMS stored" do
        sign_in_as(PROVIDER)
        get "#{MOUNT}/diagnosis_search/concepts/370143"
        assert_select "a#diagnosis-add-problem[href=?]", "#{BASE}/new?dts_id=370143", text: "Add as a problem"

        get "#{BASE}/new", params: { dts_id: "370143" }
        assert_response :ok
        assert_select "#problem-concept dd[data-icd]", text: "F32.9"
        assert_select "input#problem_pov[checked]"
        assert_select "input[name=visit_ien][value='501'][checked]"
        assert_select "input[name=visit_ien][value='400']", { count: 0 }, "an open visit from another day is not today's"
        assert_select "select#problem_status option[selected]", text: "Episodic"

        calls = post_problem(pov: "1", visit_ien: "501")
        assert_redirected_to "#{BASE}/148?visit_ien=501"
        assert_equal [ { concept_id: "370143000", status: "Episodic", laterality: nil, visit_ien: "501", provider_duz: DUZ } ],
                     calls.map { |c| c[:kwargs] }
        follow_redirect!
        assert_match "Added to the problem list and as today&#39;s purpose of visit.", response.body
        assert_select "#problem-stored dd[data-snomed]", text: "370143000"
        assert_select "#problem-stored dd[data-icd]", text: "F32.9"
        assert_select "#problem-visit-diagnoses tr[data-pov-ien='206'] td[data-icd]", text: "F32.9"
      end

      test "S-VIS-02.3 with the box cleared only the problem is added" do
        sign_in_as(PROVIDER)

        calls = post_problem(pov: "0", visit_ien: "501", outcome: { outcome: :filed, problem: STORED, diagnoses: [] })
        assert_redirected_to "#{BASE}/148"
        assert_nil calls.sole[:kwargs][:visit_ien]
        follow_redirect!
        assert_match "Added to the problem list.", response.body
        assert_select "#problem-visit-diagnoses", count: 0
      end

      test "with no open visit today it can be a problem only, and asking for the purpose of visit saves nothing" do
        sign_in_as(PROVIDER)
        answer_visits([ @yesterday ])

        get "#{BASE}/new", params: { dts_id: "370143" }
        assert_select "#problem-no-open-visit"
        assert_select "input#problem_pov", count: 0

        calls = post_problem(pov: "1", visit_ien: "400")
        assert_response :unprocessable_entity
        assert_match "The patient has no open visit today", response.body
        assert_empty calls
      end

      test "a visit that is not one of today's open visits is refused, and nothing reaches RPMS" do
        sign_in_as(PROVIDER)

        [ "400", "999", "501^1", "" ].each do |visit|
          calls = post_problem(pov: "1", visit_ien: visit)
          assert_response :unprocessable_entity, visit.inspect
          assert_match "Choose one of today&#39;s open visits.", response.body
          assert_empty calls
        end
      end

      test "a concept on the list already is shown before saving, and RPMS's duplicate answer saves nothing" do
        sign_in_as(PROVIDER)
        on_file = { ien: 148, narrative: "*Major depressive disorder" }
        RpmsStandIn.answer(ProblemEntryGateway, :check, with: { on_file: [ on_file ], new_entry: nil })

        get "#{BASE}/new", params: { dts_id: "370143" }
        assert_select "#problem-on-file li[data-problem-ien='148']"
        assert_select "#problem-form", count: 0

        post_problem(pov: "0", outcome: { outcome: :duplicate, on_file: [ on_file ] })
        assert_response :conflict
        assert_match "on the patient&#39;s problem list already. Nothing was saved.", response.body
      end

      test "a concept that asks for the side is not saved without one" do
        sign_in_as(PROVIDER)
        RpmsStandIn.answer(TerminologyGateway, :concept, with: OTITIS)

        get "#{BASE}/new", params: { dts_id: "65363" }
        assert_select "#problem-laterality input[name=laterality]", count: 3

        assert_empty post_problem(dts_id: "65363", pov: "0")
        assert_response :unprocessable_entity
        assert_match "Choose the side: Left, Right, Bilateral.", response.body

        calls = post_problem(dts_id: "65363", pov: "0", laterality: "Left")
        assert_equal "Left", calls.sole[:kwargs][:laterality]
      end

      test "RPMS refusing the user is a 403 with RPMS's reason" do
        sign_in_as(PROVIDER)

        post_problem(pov: "0", outcome: { outcome: :forbidden, reason: "BGOPROB SET is not in your menu." })
        assert_response :forbidden
        assert_match "RPMS refused this request: BGOPROB SET is not in your menu. Nothing was saved.", response.body
      end

      test "a refusal says nothing was saved; an unknown outcome says to check the list" do
        sign_in_as(PROVIDER)

        post_problem(pov: "0", outcome: { outcome: :refused, reason: "Invalid ICD code" })
        assert_response :unprocessable_entity
        assert_match "RPMS did not add the problem. Invalid ICD code Nothing was saved.", response.body

        post_problem(pov: "0", outcome: { outcome: :unknown, reason: nil })
        assert_response :unprocessable_entity
        assert_match "The outcome is unknown. Check the patient&#39;s problem list before adding it again.", response.body
      end

      test "a purpose of visit RPMS refused is said beside the problem it filed" do
        sign_in_as(PROVIDER)

        post_problem(pov: "1", visit_ien: "501", outcome: { outcome: :problem_only, problem: STORED, diagnoses: [], reason: "Visit is locked" })
        assert_redirected_to "#{BASE}/148?visit_ien=501"
        RpmsStandIn.answer(ProblemEntryGateway, :diagnoses, with: [])
        follow_redirect!
        assert_select "#problem-alert", text: /RPMS did not file it as the visit's purpose\. Visit is locked/
        assert_select "#problem-no-visit-diagnosis"
      end

      test "a user without the charting keys, or with BGOZ VIEW ONLY, cannot add one" do
        [ %w[orders_enter], %w[provider charting_view_only] ].each do |keys|
          sign_in_as(keys)
          calls = post_problem(pov: "0")
          assert_response :forbidden, keys.inspect
          assert_empty calls
        end
      end

      test "a substance use diagnosis is refused before the patient's list is read, and one on file is not shown" do
        sign_in_as(PROVIDER)
        RpmsStandIn.answer(TerminologyGateway, :concept, with: DEPRESSION.merge(icd: [ "F10.20" ]))

        get "#{BASE}/new", params: { dts_id: "370143" }
        assert_response :unprocessable_entity
        assert_match "not added to the shared problem list", response.body
        assert_empty post_problem(pov: "0")
        assert_response :unprocessable_entity
        assert_empty RpmsStandIn.calls(ProblemEntryGateway, :check), "the patient's list is not read"

        RpmsStandIn.answer(ProblemEntryGateway, :problem, with: STORED.merge(icd_code: "F11.20"))
        get "#{BASE}/148"
        assert_response :not_found
        refute_match "F11.20", response.body
      end

      test "a concept RPMS's terminology does not hold, or a problem not on the patient's list, is not found" do
        sign_in_as(PROVIDER)
        RpmsStandIn.answer(TerminologyGateway, :concept, with: nil)
        get "#{BASE}/new", params: { dts_id: "999" }
        assert_response :not_found

        RpmsStandIn.answer(ProblemEntryGateway, :problem, with: nil)
        get "#{BASE}/77"
        assert_response :not_found
      end

      private

      def sign_in_as(keys)
        @clinician_token = clinician_token(scopes: BANNER_SCOPES)
        post "#{MOUNT}/test_session", params: { duz: DUZ, user_type: "provider", security_keys: keys.join(","),
                                                smart_token: @clinician_token.plaintext_token || @clinician_token.token }
        @csrf_token = nil
        open_patient_context!(DFN)
      end

      def answer_visits(rows) = RpmsStandIn.answer(EncounterGateway, :visits, with: rows)

      # POSTs the form and answers the calls that reached ProblemEntryGateway.add.
      def post_problem(outcome: { outcome: :filed, problem: STORED, diagnoses: [ POV ] }, dts_id: "370143", **params)
        before = RpmsStandIn.calls(ProblemEntryGateway, :add).size
        RpmsStandIn.answer(ProblemEntryGateway, :add, with: ProblemEntryGateway::Result.new(**outcome))
        post BASE, params: { dts_id: dts_id, status: "Episodic" }.merge(params).merge(authenticity_token: csrf_token)
        RpmsStandIn.calls(ProblemEntryGateway, :add).drop(before)
      end
    end
  end
end
