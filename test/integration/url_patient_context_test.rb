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
    { label: "leaked backend error string", segment: "-1^Patient not found" },
    { label: "newline suffix", decoded_segment: "1\n" },
    { label: "leading spaces", decoded_segment: "  1" },
    { label: "trailing space", decoded_segment: "1 " },
    { label: "tab suffix", decoded_segment: "1\t" }
  ].freeze

  MALFORMED_CHART_AUDIT_REFUSAL_IDENTIFIERS = [
    { label: "zero", path: -> { chart_path_for("0") }, segment: "0" },
    { label: "19-digit id", path: -> { chart_path_for("9" * 19) }, segment: "9" * 19 },
    {
      label: "22-digit id with leading zeros",
      path: -> { chart_path_for("0000000000000000000001") },
      segment: "0000000000000000000001"
    },
    { label: "leading spaces", path: -> { chart_path_for_decoded_segment("  1") }, segment: "  1" },
    { label: "trailing space", path: -> { chart_path_for_decoded_segment("1 ") }, segment: "1 " },
    { label: "newline suffix", path: -> { chart_path_for_decoded_segment("1\n") }, segment: "1\n" }
  ].freeze

  MALFORMED_FHIR_CHART_REQUESTS = [
    { label: ".json format", path: ->(seg) { "#{MOUNT}/patients/#{CGI.escape(seg)}.json" }, headers: nil },
    { label: "_format=json", path: ->(seg) { "#{MOUNT}/patients/#{CGI.escape(seg)}?_format=json" }, headers: nil },
    {
      label: "Accept application/fhir+json",
      path: ->(seg) { "#{MOUNT}/patients/#{CGI.escape(seg)}" },
      headers: { "Accept" => "application/fhir+json" }
    }
  ].freeze

  INVALID_FORMAT_CHART_IDENTIFIERS.each do |example|
    next if example[:skip]

    test "invalid format chart identifier #{example[:label]} clears context and redirects to patient search" do
      with_demo_clinical_seeds do
        sign_in_clinician!
        open_patient_context!(1)
        assert_equal "1", session_open_patient_dfn

        path = if example[:decoded_segment]
                 chart_path_for_decoded_segment(example[:decoded_segment])
        else
                 chart_path_for(example[:segment])
        end
        get path
        assert_not_format_error_response!
        assert_invalid_identifier_redirect_flash_and_no_scaffold!(example[:flash_hint])
        assert_session_patient_context_cleared!
        assert_no_chart_patient_data!
      end
    end
  end

  MALFORMED_FHIR_CHART_REQUESTS.each do |variant|
    test "malformed chart id via FHIR (#{variant[:label]}) returns 400 OperationOutcome, not redirect" do
      with_demo_clinical_seeds do
        headers = user_chart_read_headers(variant[:headers] || {})
        path = variant[:path].call(MALFORMED_CHART_SEGMENT)
        Lakeraven::EHR::AuditEvent.delete_all

        get path, headers: headers

        assert_malformed_chart_fhir_refusal!(segment: MALFORMED_CHART_SEGMENT)
      end
    end
  end

  test "malformed chart id refusal is audited as a refusal, not success" do
    with_demo_clinical_seeds do
      sign_in_clinician!
      open_patient_context!(1)
      Lakeraven::EHR::AuditEvent.delete_all

      get chart_path_for(MALFORMED_CHART_SEGMENT)

      assert_redirected_to_chart_search!
      assert_malformed_chart_dfn_audit_refusal!(segment: MALFORMED_CHART_SEGMENT)
    end
  end

  MALFORMED_CHART_AUDIT_REFUSAL_IDENTIFIERS.each do |example|
    test "malformed chart id audit refusal omits entity for #{example[:label]}" do
      with_demo_clinical_seeds do
        sign_in_clinician!
        open_patient_context!(1)
        Lakeraven::EHR::AuditEvent.delete_all

        get instance_exec(&example[:path])

        assert_redirected_to_chart_search!
        assert_malformed_chart_dfn_audit_refusal!(segment: example[:segment])
      end
    end
  end

  test "well-formed chart with ?patient= audits the route dfn, not the query patient" do
    with_demo_clinical_seeds do
      travel_to Time.zone.local(2026, 10, 17, 12, 0, 0) do
        sign_in_clinician!
        open_patient_context!(1)
        assert_equal "1", session_open_patient_dfn
        Lakeraven::EHR::AuditEvent.delete_all

        get_chart_with_patient_query!(chart_path_for(1), patient: "2")

        assert_response :success
        assert_chart_derives_patient_from_url!(1)
        event = Lakeraven::EHR::AuditEvent.order(:id).last
        refute_nil event, "well-formed chart read must leave an audit row"
        assert_equal [ "Patient", "1" ], [ event.entity_type, event.entity_identifier ],
                     "?patient= must not name a record this chart did not open"
        refute_equal "2", event.entity_identifier
      end
    end
  end

  # When direct_audit_identifier is nil, audit_entity_reference must not fall back
  # to ?patient= — the query string did not open a chart for that patient.
  MALFORMED_CHART_REFUSAL_WITH_PATIENT_QUERY = [
    { label: "zero", path: -> { chart_path_for("0") }, patient: "2", segment: "0" },
    { label: "letters", path: -> { chart_path_for("abc") }, patient: "2", segment: "abc" },
    {
      label: "19-digit id",
      path: -> { chart_path_for("9" * 19) },
      patient: "Patient/2",
      segment: "9" * 19
    },
    {
      label: "percent-encoded leading space",
      path: -> { chart_path_for_decoded_segment(" 1") },
      patient: "2",
      segment: " 1"
    }
  ].freeze

  MALFORMED_CHART_REFUSAL_WITH_PATIENT_QUERY.each do |example|
    test "malformed chart id with ?patient= does not audit that patient for #{example[:label]}" do
      with_demo_clinical_seeds do
        sign_in_clinician!
        open_patient_context!(1)
        Lakeraven::EHR::AuditEvent.delete_all

        get_chart_with_patient_query!(instance_exec(&example[:path]), patient: example[:patient])

        assert_redirected_to_chart_search!
        assert_malformed_chart_dfn_audit_refusal_ignores_patient_query!(
          patient_scope: example[:patient],
          segment: example[:segment]
        )
      end
    end
  end

  test "malformed chart id .json with ?patient= does not audit that patient" do
    with_demo_clinical_seeds do
      headers = user_chart_read_headers
      Lakeraven::EHR::AuditEvent.delete_all

      get "#{MOUNT}/patients/0.json", params: { patient: "2" }, headers: headers

      assert_malformed_chart_fhir_refusal!(segment: "0")
      assert_malformed_chart_dfn_audit_refusal_ignores_patient_query!(patient_scope: "2", segment: "0")
    end
  end

  test "leading zeros on chart id are valid format and do not clear context via redirect" do
    with_demo_clinical_seeds do
      sign_in_clinician!
      open_patient_context!(1)
      assert_equal "1", session_open_patient_dfn

      get chart_path_for("007")

      refute current_response.redirect?, "007 is valid format and must not redirect to patient search"
      assert_response :success
      assert_match(/Irene/i, response.body)
      assert_equal "1", session_open_patient_dfn,
                   "valid-format chart read must not clear an unrelated open session patient"
    end
  end

  test "malformed HTML chart id clears session with patient-bound token on patient 1" do
    with_demo_clinical_seeds do
      sign_in_clinician!
      open_patient_context!(1)
      assert_equal "1", session_open_patient_dfn
      headers = patient_bound_chart_headers(patient_dfn: 1)

      get chart_path_for(MALFORMED_CHART_SEGMENT), headers: headers

      assert_not_format_error_response!
      assert_invalid_identifier_redirect_flash_and_no_scaffold!
      assert_session_patient_context_cleared!
    end
  end

  test "unauthenticated malformed chart id returns 401 without touching session patient context" do
    with_demo_clinical_seeds do
      sign_in_clinician!
      open_patient_context!(1)
      assert_equal "1", session_open_patient_dfn
      revoke_session_chart_authentication!

      get chart_path_for(MALFORMED_CHART_SEGMENT)

      assert_response :unauthorized
      assert_match(/Unauthorized/i, response.body)
      assert_equal "1", session_open_patient_dfn,
                   "format gate must not run before authentication and clear session context"
    end
  end

  test "unauthenticated malformed chart id .json returns 401 OperationOutcome without touching session" do
    with_demo_clinical_seeds do
      sign_in_clinician!
      open_patient_context!(1)
      assert_equal "1", session_open_patient_dfn
      revoke_session_chart_authentication!

      get "#{MOUNT}/patients/#{CGI.escape(MALFORMED_CHART_SEGMENT)}.json"

      assert_response :unauthorized
      assert_equal "application/fhir+json", response.media_type
      body = JSON.parse(response.body)
      assert_equal "OperationOutcome", body["resourceType"]
      assert_equal "1", session_open_patient_dfn
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
