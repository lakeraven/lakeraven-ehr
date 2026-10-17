# frozen_string_literal: true

require "test_helper"
require_relative "../support/patient_banner_test_helper"

# Pins behaviour the adversarial review found missing from the #466 spec.
class PatientBannerSpecGapsTest < ActionDispatch::IntegrationTest
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

  test "not assessed ORQQAL reply shows not-loaded on dashboard and chart" do
    with_demo_clinical_seeds do
      sign_in_clinician!
      open_patient_context!(1)
      seed_orqqal_reply!("1", [ RpmsRpc::Allergy::NOT_ASSESSED_SENTINEL ])

      get "#{MOUNT}/dashboard"
      assert_response :ok
      assert_allergies_unassessed_or_indeterminate!

      setup_chart_bearer!
      get "#{MOUNT}/patients/1", headers: @chart_headers
      assert_response :ok
      assert_allergies_unassessed_or_indeterminate!
    end
  end

  test "empty ORQQAL reply shows not-loaded on dashboard and chart" do
    with_demo_clinical_seeds do
      sign_in_clinician!
      open_patient_context!(1)
      seed_orqqal_reply!("1", [])

      get "#{MOUNT}/dashboard"
      assert_response :ok
      assert_allergies_unassessed_or_indeterminate!

      setup_chart_bearer!
      get "#{MOUNT}/patients/1", headers: @chart_headers
      assert_response :ok
      assert_allergies_unassessed_or_indeterminate!
    end
  end

  test "wire allergies owned by another patient show not-loaded not none recorded" do
    foreign_row = {
      ien: "foreign-1",
      patient_dfn: "2",
      allergen: "Sulfa Drugs",
      reaction: "Rash",
      severity: "moderate",
      clinical_status: "active"
    }

    with_demo_clinical_seeds do
      sign_in_clinician!
      open_patient_context!(1)

      with_wire_allergies_for_patient([ foreign_row ]) do
        get "#{MOUNT}/dashboard"
        assert_response :ok
        assert_allergies_unassessed_or_indeterminate!
        refute_includes response.body, "Sulfa Drugs"

        setup_chart_bearer!
        get "#{MOUNT}/patients/1", headers: @chart_headers
        assert_response :ok
        assert_allergies_unassessed_or_indeterminate!
        refute_includes response.body, "Sulfa Drugs"
      end
    end
  end

  test "screenings refusal for another patient does not show open context patient in banner" do
    with_demo_clinical_seeds do
      travel_to Time.zone.local(2026, 10, 17, 12, 0, 0) do
        sign_in_clinician!
        open_patient_context!(1)

        get "#{MOUNT}/patients/2/screenings"
        assert_response :forbidden

        body = response.body
        refute_includes body, "Alice Anderson"
        refute_match(/MRN\s*\/\s*DFN[\s\S]*?\b1\b/i, body)
        refute_includes body, "May 15, 1980"
        refute_includes body, "Penicillin"
        refute_includes body, "Shellfish"
      end
    end
  end

  test "dashboard audit names session patient not query string dfn" do
    with_demo_clinical_seeds do
      sign_in_clinician!
      open_patient_context!(1)
      Lakeraven::EHR::AuditEvent.delete_all

      get "#{MOUNT}/dashboard?dfn=2"
      assert_response :ok
      assert_audit_includes_patient!("1")
      refute_audit_patient!("2")
    end
  end

  test "dashboard audit names session patient not query string id" do
    with_demo_clinical_seeds do
      sign_in_clinician!
      open_patient_context!(1)
      Lakeraven::EHR::AuditEvent.delete_all

      get "#{MOUNT}/dashboard?id=x"
      assert_response :ok
      assert_audit_includes_patient!("1")
      refute_audit_entity_identifier!("x")
    end
  end

  test "allergies are not listed without patient identity in the same banner" do
    with_demo_clinical_seeds do
      scopes = [
        "user/AllergyIntolerance.read",
        "user/QuestionnaireResponse.read",
        "user/QuestionnaireResponse.write"
      ].join(" ")
      sign_in_clinician!(scopes: scopes)
      open_patient_context!(1)

      get "#{MOUNT}/dashboard"
      assert_response :ok

      banner = assert_patient_banner!
      refute_includes banner.text, "Alice Anderson"
      refute_match(/MRN\s*\/\s*DFN/i, banner.text)
      refute_includes banner.text, "Penicillin"
      refute_includes banner.text, "Shellfish"
      assert_allergies_state!("not-loaded")
    end
  end

  test "allergy without display text still shows visible label in banner" do
    unnamed = Lakeraven::EHR::AllergyIntolerance.new(
      ien: "code-only-1",
      patient_dfn: "1",
      allergen: nil,
      allergen_code: "7980",
      clinical_status: "active"
    )

    with_demo_clinical_seeds do
      sign_in_clinician!
      open_patient_context!(1)

      with_merged_allergies_for_patient([ unnamed ]) do
        get "#{MOUNT}/dashboard"
        assert_response :ok
        assert_allergies_state!("loaded")
        assert allergies_label_text.present?, "Expected non-blank allergy label text"
      end
    end
  end
end
