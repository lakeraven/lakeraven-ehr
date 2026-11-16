# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/patient_banner_test_helper"

module Lakeraven
  module EHR
    # The medical assistant takes vitals on one of the patient's open visits
    # (rpms-ux S-TRI-02). The gateways stand in for RPMS here, answering in
    # the shapes the build answered in; test/integration/live_vitals_test.rb
    # files them on a real RPMS and reads them back.
    class VitalsControllerTest < ActionDispatch::IntegrationTest
      include PatientBannerTestHelper

      DFN = "3"
      BASE = "#{MOUNT}/patients/#{DFN}/vitals".freeze
      MEDICAL_ASSISTANT = %w[provider orders_enter].freeze
      OPEN = { visit_ien: 501, location_ien: 3, location: "SYNTHETIC CLINIC A", service_category: "A",
               datetime: Time.utc(2026, 11, 16, 9, 30), locked: false }.freeze
      VALID = { valid: true, errors: [] }.freeze
      SAVED = { success: true, measurement_count: 1, raw: "0" }.freeze
      # BEHOVM VALIDATE's refusal of a systolic of 400 on bcer-9.0.
      BP_400 = { valid: false, errors: [ { index: 0, abbreviation: "BP", value: "400/80",
                                           error_message: "Systolic pressure must be between 20 and 275 mmHg." } ] }.freeze

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

      test "S-TRI-02.1 a medical assistant takes vitals on the patient's open visit, and RPMS files them on it" do
        get "#{MOUNT}/patients/#{DFN}"
        assert_select "a[href=?]", "#{BASE}/new", text: "Take vitals"

        saves = post_vitals({ "WT" => "169", "BP" => "117/77", "PU" => "80" })
        assert_redirected_to "#{MOUNT}/patients/#{DFN}"
        dfn, visit_string, measurements = saves.first[:args]
        assert_equal [ DFN, "3;3261116.0930;A;501" ], [ dfn, visit_string ], "filed on the visit chosen"
        assert_equal [ %w[WT 169], %w[BP 117/77], %w[PU 80] ], measurements.map { |m| m.values_at(:abbreviation, :value) }
        assert_equal DUZ, saves.first[:kwargs][:provider_duz].to_s, "as the signed-on user"
      end

      test "S-TRI-02.1 the vitals are filed at the site's time, not the app host's UTC clock" do
        # 21:30 on Sunday Nov 15 Pacific is already Monday 05:30 in UTC.
        site_now = Time.new(2026, 11, 15, 21, 30, 0, "-08:00")
        Lakeraven::EHR::SiteTime.reader = -> { site_now }
        travel_to Time.utc(2026, 11, 16, 5, 30) do
          saves = post_vitals({ "WT" => "169" })
          assert_equal site_now, saves.first[:kwargs][:taken_at], "the time sent is the site's"
        end
      ensure
        Lakeraven::EHR::SiteTime.reader = -> { Time.now }
      end

      test "S-TRI-02.2 a value RPMS refuses shows RPMS's reason and files nothing" do
        saves = post_vitals({ "BP" => "400/80" }, validation: BP_400)

        assert_response :unprocessable_entity
        assert_match "Systolic pressure must be between 20 and 275 mmHg.", response.body
        assert_select "input[name='vitals[BP]'][value='400/80']", 1, "the value is kept to correct"
        assert_empty saves
      end

      test "S-TRI-02.3 a PHQ-2 score is filed with the other vitals" do
        saves = post_vitals({ "PHQ2" => "2", "WT" => "169" })

        assert_equal %w[WT PHQ2], saves.first[:args].last.map { |m| m[:abbreviation] }
      end

      test "S-TRI-02.1 no visit, a visit not open, no value or a value that is not a number files nothing" do
        [ [ "999", { "WT" => "169" } ], [ "501", {} ], [ "501", { "WT" => "heavy" } ], [ "501", { "BP" => "120^80" } ] ].each do |visit, values|
          saves = post_vitals(values, visit_ien: visit)
          assert_response :unprocessable_entity
          assert_empty saves, [ visit, values ].inspect
        end
      end

      test "S-TRI-02.1 a user with BGOZ VIEW ONLY cannot take vitals" do
        sign_in_as(%w[provider charting_view_only])
        assert_empty post_vitals({ "WT" => "169" })
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

      # POSTs the form and answers the calls that reached VitalGateway.add.
      def post_vitals(values, visit_ien: "501", validation: VALID)
        StubHelpers.with_stub(EncounterGateway, :visits, [ OPEN ]) do
          StubHelpers.with_stub(VitalGateway, :validate, validation) do
            StubHelpers.with_recording_stub(VitalGateway, :add, SAVED) do |calls|
              post BASE, params: { visit_ien: visit_ien, vitals: values, authenticity_token: csrf_token }
              return calls
            end
          end
        end
      end
    end
  end
end
