# frozen_string_literal: true

require "test_helper"
require_relative "../support/patient_banner_test_helper"

# Allergies field contract for the persistent patient banner (#466).
class PatientBannerAllergiesTest < ActionDispatch::IntegrationTest
  include PatientBannerTestHelper
  include SupplementalProviderConfigHelper

  setup do
    enable_forgery_protection!
    Lakeraven::EHR::AuditEvent.delete_all
  end

  teardown do
    restore_forgery_protection!
    teardown_oauth!
    Lakeraven::EHR::AuditEvent.delete_all
  end

  test "zero loaded allergies show none recorded on dashboard and chart" do
    with_demo_clinical_seeds do
      sign_in_clinician!
      open_patient_context!(3)

      get "#{MOUNT}/dashboard"
      assert_response :ok
      assert_allergies_state!("none-recorded", text_fragment: "None recorded")

      setup_chart_bearer!
      get "#{MOUNT}/patients/3", headers: @chart_headers
      assert_response :ok
      assert_allergies_state!("none-recorded", text_fragment: "None recorded")
      refute_includes response.body, "No Known Allergies"
    end
  end

  test "allergy source error shows not loaded on dashboard and chart" do
    with_demo_clinical_seeds do
      sign_in_clinician!
      open_patient_context!(1)

      with_allergy_source_raising do
        get "#{MOUNT}/dashboard"
        assert_response :ok
        assert_allergies_state!("not-loaded", text_fragment: "Not loaded")
        refute_includes response.body, "None recorded"
        refute_includes response.body, "No Known Allergies"

        setup_chart_bearer!
        get "#{MOUNT}/patients/1", headers: @chart_headers
        assert_response :ok
        assert_allergies_state!("not-loaded", text_fragment: "Not loaded")
        refute_includes response.body, "None recorded"
        refute_includes response.body, "No Known Allergies"
      end
    end
  end

  test "withheld allergies without read scope show not loaded on dashboard and chart" do
    with_demo_clinical_seeds do
      scopes = BANNER_SCOPES.gsub("user/AllergyIntolerance.read", "").squeeze(" ")
      sign_in_clinician!(scopes: scopes)
      open_patient_context!(1)

      get "#{MOUNT}/dashboard"
      assert_response :ok
      assert_allergies_state!("not-loaded", text_fragment: "Not loaded")
      refute_includes response.body, "None recorded"

      narrow = CHART_SCOPES.gsub("system/*.read", "system/Patient.read system/Condition.read")
      setup_chart_bearer!(scopes: narrow)
      get "#{MOUNT}/patients/1", headers: @chart_headers
      assert_response :ok
      assert_allergies_state!("not-loaded", text_fragment: "Not loaded")
      refute_includes response.body, "None recorded"
      refute_includes response.body, "No Known Allergies"
    end
  end

  test "part2 egress filter dropping allergies shows not loaded on chart" do
    with_demo_clinical_seeds do
      setup_chart_bearer!
      with_egress_bundle_after_filter(->(payload) { strip_allergy_intolerances_from_bundle(payload) }) do
        get "#{MOUNT}/patients/1", headers: @chart_headers
        assert_response :ok
        assert_allergies_state!("not-loaded", text_fragment: "Not loaded")
        refute_includes response.body, "None recorded"
        refute_includes response.body, "No Known Allergies"
      end
    end
  end
end
