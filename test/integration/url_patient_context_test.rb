# frozen_string_literal: true

require "test_helper"
require_relative "../support/url_patient_context_test_helper"

# URL-derived patient context with self-clearing on invalid identifiers (#467).
#
# Valid record id (format only, per Patient.canonical_dfn): one or more ASCII
# digits whose integer value is positive. Leading zeros canonicalize ("01" and
# "1" are the same id). Zero, negative values, non-digits, empty strings, ids
# longer than MAX_CHART_DFN_DIGITS, and leaked backend error text are invalid
# format. A well-formed id with no record (e.g. 99999) is not a format error.
class UrlPatientContextTest < ActionDispatch::IntegrationTest
  include UrlPatientContextTestHelper
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

  test "canonical_dfn defines valid record id format for chart routes" do
    assert_valid_canonical_dfn!("1", expected: "1")
    assert_valid_canonical_dfn!("007", expected: "7")
    assert_valid_canonical_dfn!(" 42 ", expected: "42")
    assert_nil Lakeraven::EHR::Patient.canonical_dfn("0")
    assert_nil Lakeraven::EHR::Patient.canonical_dfn("-1")
    assert_nil Lakeraven::EHR::Patient.canonical_dfn("abc")
    assert_nil Lakeraven::EHR::Patient.canonical_dfn("")
    assert_nil Lakeraven::EHR::Patient.canonical_dfn("-1^Patient not found")
  end

  test "GET chart never opens session patient context" do
    with_demo_clinical_seeds do
      travel_to Time.zone.local(2026, 10, 17, 12, 0, 0) do
        sign_in_clinician!
        assert_nil session_open_patient_dfn

        get_chart_for_dfn!(1)
        assert_response :success
        assert_get_chart_does_not_open_session_context!
      end
    end
  end

  test "refreshing the chart re-derives patient and banner from the URL dfn" do
    with_demo_clinical_seeds do
      travel_to Time.zone.local(2026, 10, 17, 12, 0, 0) do
        sign_in_clinician!

        get_chart_for_dfn!(1)
        assert_chart_derives_patient_from_url!(1)
        assert_get_chart_does_not_open_session_context!

        get_chart_for_dfn!(1)
        assert_chart_derives_patient_from_url!(1)
        assert_get_chart_does_not_open_session_context!
      end
    end
  end

  test "route dfn wins over a different open session patient without opening context via GET" do
    with_demo_clinical_seeds do
      travel_to Time.zone.local(2026, 10, 17, 12, 0, 0) do
        sign_in_clinician!
        open_patient_context!(2)
        assert_equal "2", session_open_patient_dfn

        get_chart_for_dfn!(1)
        assert_chart_derives_patient_from_url!(1)
        assert_equal "2", session_open_patient_dfn,
                     "GET must not re-bind session context to the URL patient"
      end
    end
  end

  test "well-formed unknown patient id is not a format error" do
    with_demo_clinical_seeds do
      sign_in_clinician!
      open_patient_context!(1)
      assert_equal "1", session_open_patient_dfn

      get_chart_for_dfn!(99999)
      assert_response :not_found
      assert_match(/not found/i, response.body)
      assert_equal "1", session_open_patient_dfn,
                   "not-found must not be confused with format-invalid context clearing"
    end
  end

  test "canonicalized leading zeros on unknown patient are not a format error" do
    with_demo_clinical_seeds do
      sign_in_clinician!

      get chart_path_for("00099999")
      assert_response :not_found
      assert_match(/not found/i, response.body)
    end
  end

  INVALID_FORMAT_CHART_IDENTIFIERS = [
    { label: "letters", segment: "abc" },
    { label: "empty segment", segment: "", skip: "no chart route for empty dfn segment" },
    { label: "zero", segment: "0", flash_hint: "0" },
    { label: "negative", segment: "-1" },
    { label: "over max dfn digits", segment: "9" * (MAX_CHART_DFN_DIGITS + 1) },
    { label: "sql injection", segment: "1; DROP TABLE" },
    { label: "html injection", segment: "<script>" },
    { label: "encoded quote", segment: "1%27" },
    { label: "leaked backend error string", segment: "-1^Patient not found" }
  ].freeze

  INVALID_FORMAT_CHART_IDENTIFIERS.each do |example|
    next if example[:skip]

    test "invalid format chart identifier #{example[:label]} clears context and redirects to patient search" do
      with_demo_clinical_seeds do
        sign_in_clinician!
        open_patient_context!(1)
        assert_equal "1", session_open_patient_dfn

        get chart_path_for(example[:segment])
        assert_not_format_error_response!
        assert_redirected_to_chart_search!
        assert_invalid_identifier_flash!(example[:flash_hint])
        follow_chart_search_redirect!
        assert_session_patient_context_cleared!
        assert_no_chart_patient_data!
      end
    end
  end

  test "backend chart load failure clears context and renders explicit error state" do
    with_demo_clinical_seeds do
      sign_in_clinician!
      open_patient_context!(1)

      without_show_exceptions do
        with_patient_repository_raising do
          get_chart_for_dfn!(1)
        end
      end
      assert_chart_load_error_state!
      assert_session_patient_context_cleared!
    end
  end
end
