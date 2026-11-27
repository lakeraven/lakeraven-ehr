# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/patient_banner_test_helper"

module Lakeraven
  module EHR
    # The vaccines a patient is due for, from RPMS's forecast (#865). The
    # stand-in answers the forecast here; features/immunization/vaccines_due.feature
    # reads it from a real RPMS.
    class ImmunizationForecastsControllerTest < ActionDispatch::IntegrationTest
      include PatientBannerTestHelper

      DFN = "3"
      OTHER_DFN = "2"
      DUE = "#{MOUNT}/patients/#{DFN}/immunizations/due".freeze

      setup do
        enable_forgery_protection!
        @original_client = RpmsRpc.configuration.client
        RpmsStandIn.install! do |rpms|
          LakeravenDemoSeeds.seed(rpms)
          rpms.answer(RpmsRpc::Immunization, :forecast, DFN, with: [ { vaccine: "Td", status: "DUE NOW", risk_based: false } ])
        end
        sign_in_clinician!(scopes: "#{BANNER_SCOPES} user/Immunization.read")
        open_patient_context!(DFN)
      end

      teardown do
        restore_forgery_protection!
        teardown_oauth!
        RpmsRpc.configure { |c| c.client = @original_client }
      end

      test "a patient-scoped token bound to another patient cannot read this one's vaccines due" do
        other = clinician_token(scopes: "patient/Immunization.read", app_name: "smart-patient-app", duz: OTHER_DFN)

        get DUE, headers: bearer_headers(other)

        assert_response :forbidden
        assert_equal "Forbidden: Patient context mismatch", response.body
        assert_empty RpmsStandIn.calls(RpmsRpc::Immunization, :forecast)
      end
    end
  end
end
