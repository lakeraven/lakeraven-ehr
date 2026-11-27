# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/patient_banner_test_helper"

module Lakeraven
  module EHR
    # The medical assistant records the chief complaint on one of the
    # patient's open visits (rpms-ux S-TRI-07.1). The gateways stand in for
    # RPMS here; test/integration/live_chief_complaint_test.rb files it on a
    # real RPMS and reads it back.
    class ChiefComplaintsControllerTest < ActionDispatch::IntegrationTest
      include PatientBannerTestHelper

      DFN = "3"
      BASE = "#{MOUNT}/patients/#{DFN}/chief_complaints".freeze
      MEDICAL_ASSISTANT = %w[provider orders_enter].freeze
      OPEN = { visit_ien: 501, location: "SYNTHETIC CLINIC A", datetime: Time.zone.local(2026, 11, 16, 9, 30), locked: false }.freeze
      LOCKED = OPEN.merge(visit_ien: 502, locked: true).freeze
      FILED = { success: true, ien: 41, raw: "41", error: nil }.freeze

      setup do
        enable_forgery_protection!
        @original_client = RpmsRpc.configuration.client
        RpmsStandIn.install! { |rpms| LakeravenDemoSeeds.seed(rpms) }
      end

      teardown do
        restore_forgery_protection!
        teardown_oauth!
        RpmsRpc.configure { |c| c.client = @original_client }
      end

      test "S-TRI-07.1 a medical assistant records the chief complaint on the patient's open visit, and RPMS files it there" do
        sign_in_as(MEDICAL_ASSISTANT)
        get "#{MOUNT}/patients/#{DFN}"
        assert_select "a[href=?]", "#{BASE}/new", text: "Record chief complaint"

        with_visits([ OPEN, LOCKED ]) { get "#{BASE}/new" }
        assert_response :ok
        assert_select "input[name=visit_ien][value='501']"
        assert_select "input[name=visit_ien][value='502']", { count: 0 }, "a locked visit is not offered"

        calls = post_chief_complaint(visit_ien: "501", chief_complaint: "Joint pain and nausea for 4 days")
        assert_redirected_to "#{MOUNT}/patients/#{DFN}"
        assert_equal [ [ "501", "Joint pain and nausea for 4 days" ] ], calls.map { |c| c[:args] }
        follow_redirect!
        assert_match "Chief complaint recorded on the visit.", response.body
      end

      test "S-TRI-07.1 a visit that is not open now is refused, and nothing reaches RPMS" do
        sign_in_as(MEDICAL_ASSISTANT)

        [ "502", "999", "501^1", "" ].each do |visit|
          calls = post_chief_complaint(visit_ien: visit, chief_complaint: "Cough")
          assert_response :unprocessable_entity
          assert_match "Choose one of the patient&#39;s open visits.", response.body
          assert_empty calls, visit.inspect
        end
      end

      test "S-TRI-07.1 text the visit's narrative cannot carry is refused, and nothing reaches RPMS" do
        sign_in_as(MEDICAL_ASSISTANT)

        [ "", "pain^nausea", "x" * 241 ].each do |text|
          calls = post_chief_complaint(visit_ien: "501", chief_complaint: text)
          assert_response :unprocessable_entity
          assert_empty calls, text.inspect
        end
      end

      test "S-TRI-07.1 RPMS refusing it says nothing was saved; a broken connection says the outcome is unknown" do
        sign_in_as(MEDICAL_ASSISTANT)

        post_chief_complaint(visit_ien: "501", chief_complaint: "Cough", reply: { success: false, error: :refused, raw: "-1003^Visit is locked" })
        assert_response :unprocessable_entity
        assert_match "RPMS did not record the chief complaint. Nothing was saved.", response.body
        refute_match "Visit is locked", response.body, "the broker's text is not shown"

        post_chief_complaint(visit_ien: "501", chief_complaint: "Cough", reply: IOError.new("closed"))
        assert_response :unprocessable_entity
        assert_match "The outcome is unknown.", response.body
      end

      test "S-TRI-07.1 a user without the charting keys, or with BGOZ VIEW ONLY, cannot record one" do
        [ %w[orders_enter], %w[provider charting_view_only], %w[scheduling_user] ].each do |keys|
          sign_in_as(keys)
          calls = post_chief_complaint(visit_ien: "501", chief_complaint: "Cough")
          assert_response :forbidden, keys.inspect
          assert_empty calls
        end
      end

      # VisitCharting's gate, so every form that charts on a visit is walked.
      test "a patient-scoped token bound to another patient cannot open charting on this one's visits" do
        sign_in_as(MEDICAL_ASSISTANT)
        other = clinician_token(scopes: "patient/*.read", app_name: "smart-patient-app", duz: "2")

        %w[chief_complaints vitals allergy_reviews problems].each do |form|
          with_visits([ OPEN ]) { get "#{MOUNT}/patients/#{DFN}/#{form}/new", headers: bearer_headers(other) }

          assert_response :forbidden, form
          assert_equal "Forbidden: Patient context mismatch", response.body, form
        end
      end

      private

      def sign_in_as(keys)
        @clinician_token = clinician_token(scopes: BANNER_SCOPES)
        post "#{MOUNT}/test_session", params: { duz: DUZ, user_type: "provider", security_keys: keys.join(","),
                                                smart_token: @clinician_token.plaintext_token || @clinician_token.token }
        @csrf_token = nil
        open_patient_context!(DFN)
      end

      def with_visits(rows, &) = StubHelpers.with_stub(EncounterGateway, :visits, rows, &)

      # POSTs the form and answers the calls that reached ChiefComplaintGateway.record.
      def post_chief_complaint(reply: FILED, **params)
        calls = []
        restore = StubHelpers.send(:singleton_method_restore, ChiefComplaintGateway, :record)
        ChiefComplaintGateway.define_singleton_method(:record) do |*args|
          calls << { args: args }
          reply.is_a?(Exception) ? raise(reply) : reply
        end
        with_visits([ OPEN, LOCKED ]) { post BASE, params: params.merge(authenticity_token: csrf_token) }
        calls
      ensure
        restore&.call
      end
    end
  end
end
