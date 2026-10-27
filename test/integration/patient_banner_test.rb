# frozen_string_literal: true

require "test_helper"
require_relative "../support/patient_banner_test_helper"

# Specification for the layout-level persistent patient banner (#466).
class PatientBannerTest < ActionDispatch::IntegrationTest
  include PatientBannerTestHelper
  include ActiveSupport::Testing::TimeHelpers

  setup do
    enable_forgery_protection!
    Lakeraven::EHR::AuditEvent.delete_all
  end

  teardown do
    restore_forgery_protection!
    teardown_oauth!
    Lakeraven::EHR::AuditEvent.delete_all
  end

  test "dashboard and screenings render sticky patient banner with demographics when context is open" do
    with_demo_clinical_seeds do
      travel_to Time.zone.local(2026, 10, 17, 12, 0, 0) do
        sign_in_clinician!
        open_patient_context!(1)

        get "#{MOUNT}/dashboard"
        assert_response :ok
        assert_banner_demographics!(
          name: "Alice Anderson",
          mrn: "1",
          dob: "May 15, 1980",
          age: "46",
          sex: "Female"
        )
        assert_banner_sticky_stylesheet!

        get "#{MOUNT}/patients/1/screenings"
        assert_response :ok
        assert_patient_banner!
        assert_banner_demographics!(
          name: "Alice Anderson",
          mrn: "1",
          dob: "May 15, 1980",
          age: "46",
          sex: "Female"
        )
      end
    end
  end

  test "HTML chart renders patient banner with demographics and loaded allergies" do
    with_demo_clinical_seeds do
      setup_chart_bearer!
      travel_to Time.zone.local(2026, 10, 17, 12, 0, 0) do
        get "#{MOUNT}/patients/1", headers: @chart_headers
        assert_response :ok
        assert_banner_demographics!(
          name: "Alice Anderson",
          mrn: "1",
          dob: "May 15, 1980",
          age: "46",
          sex: "Female"
        )
        assert_allergies_state!("loaded")
        assert_includes allergies_field_node.text, "Penicillin"
        assert_includes allergies_field_node.text, "Shellfish"
      end
    end
  end

  test "signed in with no patient context shows empty banner without identifiers" do
    sign_in_clinician!
    get "#{MOUNT}/dashboard"
    assert_response :ok
    assert_empty_banner!
    refute_includes response.body, "Alice Anderson"
    refute_includes response.body, "111-11-1111"
  end

  test "login page renders no patient banner or patient identifiers" do
    get "#{MOUNT}/login"
    assert_response :ok
    assert_nil patient_banner_node
    refute_includes response.body, "Alice Anderson"
    refute_includes response.body, "No patient selected"
  end

  test "clear patient context removes session binding and shows empty state" do
    with_demo_clinical_seeds do
      sign_in_clinician!
      open_patient_context!(1)
      get "#{MOUNT}/dashboard"
      assert_response :ok

      submit_clear_patient_context!
      assert_response :success
      assert_empty_banner!
      assert_nil session[:open_patient_dfn]

      get "#{MOUNT}/dashboard"
      assert_response :ok
      refute_includes response.body, "Alice Anderson"
      refute_includes response.body, "Penicillin"
      refute_includes response.body, "Shellfish"

      get "#{MOUNT}/patients/1/screenings"
      assert_response :forbidden
      assert_includes response.body, "This record is not open in your session"
    end
  end
end
