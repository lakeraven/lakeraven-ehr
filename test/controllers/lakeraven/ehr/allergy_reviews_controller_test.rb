# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/patient_banner_test_helper"

module Lakeraven
  module EHR
    # The medical assistant marks the allergies reviewed on one of the
    # patient's open visits (rpms-ux S-TRI-04.1). The gateways stand in for
    # RPMS here; test/integration/live_allergy_review_test.rb files the review
    # on a real RPMS and reads it back.
    class AllergyReviewsControllerTest < ActionDispatch::IntegrationTest
      include PatientBannerTestHelper

      DFN = "3"
      BASE = "#{MOUNT}/patients/#{DFN}/allergy_reviews".freeze
      MEDICAL_ASSISTANT = %w[provider orders_enter].freeze
      OPEN = { visit_ien: 501, location: "SYNTHETIC CLINIC A", datetime: Time.utc(2026, 11, 16, 9, 30), locked: false }.freeze
      LOCKED = OPEN.merge(visit_ien: 502, locked: true).freeze
      FILED = { success: true, ien: 9, raw: "9^501", error: nil }.freeze

      setup do
        enable_forgery_protection!
        @original_client = RpmsRpc.configuration.client
        RpmsRpc.mock! { |m| LakeravenDemoSeeds.seed(m) }
        sign_in_as(MEDICAL_ASSISTANT)
      end

      teardown do
        restore_forgery_protection!
        teardown_oauth!
        RpmsRpc.configure { |c| c.client = @original_client }
      end

      test "S-TRI-04.1 a medical assistant marks the allergies reviewed on the patient's open visit, and RPMS records it there" do
        get "#{MOUNT}/patients/#{DFN}"
        assert_select "a[href=?]", "#{BASE}/new", text: "Mark allergies reviewed"
        StubHelpers.with_stub(EncounterGateway, :visits, [ OPEN, LOCKED ]) { get "#{BASE}/new" }
        assert_select "input[name=visit_ien]", 1, "only the open visit is offered"

        calls = post_review("501")
        assert_redirected_to "#{MOUNT}/patients/#{DFN}"
        assert_equal [ [ DFN, "501" ] ], calls.map { |c| c[:args] }
        follow_redirect!
        assert_match "Allergies marked reviewed on the visit.", response.body
      end

      test "S-TRI-04.1 a visit that is not open now files nothing, and RPMS refusing says nothing was saved" do
        [ "502", "999", "" ].each do |visit|
          assert_empty post_review(visit), visit.inspect
          assert_response :unprocessable_entity
        end

        post_review("501", reply: { success: false, error: :wrong_patient })
        assert_response :unprocessable_entity
        assert_match "RPMS did not record the review. Nothing was saved.", response.body
      end

      test "S-TRI-04.1 a user with BGOZ VIEW ONLY cannot mark the allergies reviewed" do
        sign_in_as(%w[provider charting_view_only])
        assert_empty post_review("501")
        assert_response :forbidden
      end

      private

      def sign_in_as(keys)
        @clinician_token = clinician_token(scopes: BANNER_SCOPES)
        post "#{MOUNT}/test_session", params: { duz: DUZ, user_type: "provider", security_keys: keys.join(","),
                                                smart_token: @clinician_token.plaintext_token || @clinician_token.token }
        @csrf_token = nil
        open_patient_context!(DFN)
      end

      # POSTs the form and answers the calls that reached the gateway.
      def post_review(visit_ien, reply: FILED)
        StubHelpers.with_stub(EncounterGateway, :visits, [ OPEN, LOCKED ]) do
          StubHelpers.with_recording_stub(ClinicalReviewGateway, :allergies_reviewed, reply) do |calls|
            post BASE, params: { visit_ien: visit_ien, authenticity_token: csrf_token }
            return calls
          end
        end
      end
    end
  end
end
