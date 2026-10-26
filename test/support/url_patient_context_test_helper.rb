# frozen_string_literal: true

require_relative "patient_banner_test_helper"
require_relative "stub_helpers"

# Shared helpers for URL-derived patient context (#467).
module UrlPatientContextTestHelper
  include PatientBannerTestHelper

  # Patient search for clinicians is the dashboard (see dashboards#show and
  # active_patient_contexts_controller redirect_to dashboard_path).
  CHART_SEARCH_PATH = "#{MOUNT}/dashboard".freeze

  # Patient.canonical_dfn accepts one or more ASCII digits whose integer value
  # is positive; leading zeros canonicalize ("007" -> "7"). Zero is rejected
  # (not a valid record id). There is no max length in canonical_dfn today;
  # chart routes treat more than 18 decimal digits as invalid format because
  # that exceeds VistA DFN width.
  MAX_CHART_DFN_DIGITS = 18

  def assert_valid_canonical_dfn!(raw, expected:)
    assert_equal expected, Lakeraven::EHR::Patient.canonical_dfn(raw),
                 "Patient.canonical_dfn(#{raw.inspect})"
  end

  def chart_test_session
    if respond_to?(:integration_session)
      session
    else
      last_request.env.fetch("rack.session")
    end
  end

  def session_open_patient_dfn
    chart_test_session[Lakeraven::EHR::ClinicianPatientContext::SESSION_KEY]
  end

  def get_chart_for_dfn!(dfn, headers: nil)
    path = chart_path_for(dfn)
    if headers
      get path, headers: headers
    else
      get path
    end
  end

  def chart_path_for(dfn)
    segment = dfn.to_s
    if segment.match?(%r{\A[\d%]+\z})
      "#{MOUNT}/patients/#{segment}"
    else
      "#{MOUNT}/patients/#{CGI.escape(segment)}"
    end
  end

  # Percent-encode each byte of the routed segment once (e.g. "1\n" -> "1%0A").
  # Integration `get` must not pass a literal "1%0A" string through chart_path_for,
  # which treats percent sequences as opaque path text.
  def chart_path_for_decoded_segment(segment)
    "#{MOUNT}/patients/#{encode_chart_path_segment_once(segment)}"
  end

  def encode_chart_path_segment_once(segment)
    segment.to_s.bytes.map do |byte|
      if byte.chr.match?(/[A-Za-z0-9\-._~]/)
        byte.chr
      else
        format("%%%02X", byte)
      end
    end.join
  end

  def assert_redirected_to_chart_search!
    resp = current_response
    assert resp.redirect?, "expected redirect to patient search (dashboard), got #{resp.status}"
    location = resp.headers["Location"].to_s
    assert location.end_with?(CHART_SEARCH_PATH), "expected dashboard chart search, got #{location}"
  end

  def follow_chart_search_redirect!
    follow_redirect!
    assert_equal 200, current_response.status
  end

  def assert_no_flash_scaffold_header!(response = current_response)
    header = response.headers["X-Message-Flash-Alert"]
    assert header.blank?,
           "X-Message-Flash-Alert is test scaffolding and must not be set in production (#{header.inspect})"
  end

  def assert_invalid_identifier_flash!(hint = nil)
    body = current_response.body
    assert_match(/not a valid record id/i, body,
                 "dashboard must render the explanatory flash in the page body")
    assert_match(/patient|identifier|record|invalid/i, body)
    assert_match(Regexp.new(Regexp.escape(hint), Regexp::IGNORECASE), body) if hint.present?
  end

  def assert_invalid_identifier_redirect_flash_and_no_scaffold!(hint = nil)
    assert_redirected_to_chart_search!
    redirect_response = current_response
    follow_chart_search_redirect!
    assert_invalid_identifier_flash!(hint)
    assert_no_flash_scaffold_header!(redirect_response)
  end

  def user_chart_read_headers(extra = {})
    token = clinician_token(scopes: BANNER_SCOPES, app_name: "url-patient-context-fhir")
    bearer_headers(token).merge(extra)
  end

  def patient_bound_chart_headers(patient_dfn:, scopes: "patient/*.read")
    token = clinician_token(scopes: scopes, app_name: "patient-bound-chart", duz: patient_dfn.to_s)
    bearer_headers(token)
  end

  def revoke_session_chart_authentication!
    raw = chart_test_session[:smart_token].presence
    if raw.present?
      token = Doorkeeper::AccessToken.by_token(raw)
      token&.revoke
    end
    chart_test_session.delete(:smart_token)
    chart_test_session.delete(:last_seen_at)
  end

  MALFORMED_CHART_SEGMENT = "not-a-valid-dfn"

  def assert_malformed_chart_fhir_refusal!(segment: MALFORMED_CHART_SEGMENT)
    resp = current_response
    refute resp.redirect?,
           "FHIR chart caller must not redirect (got #{resp.status} Location=#{resp.headers['Location']})"
    assert_equal 400, resp.status, resp.body[0, 500]
    assert_equal "application/fhir+json", resp.media_type
    body = JSON.parse(resp.body)
    assert_equal "OperationOutcome", body["resourceType"]
    issue_code = body.dig("issue", 0, "code")
    assert_includes %w[invalid value], issue_code, "expected invalid/value issue code, got #{issue_code.inspect}"
    refute_includes resp.body, segment, "raw malformed id must not appear in the OperationOutcome body"
  end

  def assert_malformed_chart_dfn_audit_refusal!(segment: MALFORMED_CHART_SEGMENT)
    event = Lakeraven::EHR::AuditEvent.order(:id).last
    refute_nil event, "malformed chart id request must leave an audit row"
    refute_equal "0", event.outcome,
                 "malformed identifier refusal must not be audited as success (outcome #{event.outcome})"
    assert event.entity_identifier.blank?,
           "malformed identifier refusal must not attribute a patient " \
           "(entity_identifier #{event.entity_identifier.inspect})"
    desc = event.outcome_desc.to_s
    assert_match(/invalid|identifier|valid record/i, desc,
                 "refusal outcome_desc must name the invalid identifier problem")
    refute_includes desc, segment, "raw malformed id must not be stored in outcome_desc"
  end

  # URL-derived context: the chart and banner reflect the route dfn, not session.
  def assert_chart_derives_patient_from_url!(dfn)
    resp = current_response
    assert_equal 200, resp.status, resp.body[0, 500]
    case dfn.to_s
    when "1"
      assert_includes resp.body, "Alice Anderson"
      refute_includes resp.body, "MOUSE,MICKEY"
      assert_banner_demographics!(
        name: "Alice Anderson",
        mrn: "1",
        dob: "May 15, 1980",
        age: "46",
        sex: "Female"
      )
    else
      flunk "Add chart/banner expectations for synthetic patient #{dfn}"
    end
  end

  def assert_get_chart_does_not_open_session_context!
    assert_nil session_open_patient_dfn,
               "GET /patients/:dfn must not open session patient context (POST only)"
  end

  def assert_session_patient_context_cleared!
    assert_nil session_open_patient_dfn
    get "#{MOUNT}/patients/1/screenings"
    assert_equal 403, current_response.status,
                 "expected screenings to refuse when session patient context is cleared"
  end

  def assert_no_chart_patient_data!
    body = current_response.body
    refute_includes body, "Alice Anderson"
    refute_includes body, "Type 2 diabetes mellitus"
    refute_includes body, "Lisinopril 10mg"
    refute_includes body, "Penicillin"
  end

  def assert_not_format_error_response!
    status = current_response.status
    refute_equal 404, status,
                 "format-invalid chart ids must redirect to search, not 404 (got #{status})"
  end

  # Backend chart load failure: explicit error page, not a 200 with an empty chart.
  # 503 — the RPMS/repository layer is unavailable (same class as
  # ChartsController#render_unrecorded_access_denial).
  CHART_BACKEND_FAILURE_STATUS = 503

  def chart_response_for_load_error_assertions
    if instance_variable_defined?(:@chart_response) && @chart_response
      @chart_response
    else
      current_response
    end
  end

  def assert_chart_load_error_state!
    resp = chart_response_for_load_error_assertions
    assert_equal CHART_BACKEND_FAILURE_STATUS, resp.status,
                 "backend failure must not return 200 with an empty chart (got #{resp.status})"
    body = resp.body
    assert_match(/chart could not be loaded|could not load this chart|service unavailable/i, body,
                 "expected an explicit chart error state")
    refute_includes body, "Type 2 diabetes mellitus", "clinical sections must not render on load failure"
    refute_includes body, "Lisinopril 10mg"
    assert_empty_banner_in_html!(body)
  end

  def assert_empty_banner_in_html!(html)
    banner = Nokogiri::HTML(html).at_css("#patient-banner")
    assert banner, "Expected #patient-banner on the page"
    assert_includes banner.text, "No patient selected"
    link = banner.css("a").find { |a| a.text.match?(/chart search/i) }
    assert link, "Expected a chart search link in the empty banner"
    assert link["href"].present?, "Chart search link must have an href"
  end

  def without_show_exceptions
    env = Rails.application.env_config
    key = "action_dispatch.show_exceptions"
    previous = env[key]
    env[key] = false
    yield
  ensure
    env[key] = previous
  end

  def with_patient_repository_raising(message = "rpms unavailable")
    repo = Lakeraven::EHR::PatientRepository.singleton_class
    restore = StubHelpers.send(:singleton_method_restore, Lakeraven::EHR::PatientRepository, :find)
    Lakeraven::EHR::PatientRepository.define_singleton_method(:find) do |*_args, **_kwargs|
      raise StandardError, message
    end
    yield
  ensure
    restore&.call
  end
end
