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

  def assert_invalid_identifier_flash!(hint = nil)
    message = flash_alert_message
    assert message.present?, "expected flash alert explaining the identifier problem"
    assert_match(/patient|identifier|record|invalid|not found/i, message)
    assert_match(Regexp.new(Regexp.escape(hint), Regexp::IGNORECASE), message) if hint.present?
  end

  def flash_alert_message
    if respond_to?(:flash)
      flash[:alert].to_s
    else
      current_response.headers["X-Message-Flash-Alert"].to_s
    end
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

  def assert_chart_load_error_state!
    resp = current_response
    assert_equal CHART_BACKEND_FAILURE_STATUS, resp.status,
                 "backend failure must not return 200 with an empty chart (got #{resp.status})"
    body = resp.body
    assert_match(/chart could not be loaded|could not load this chart|service unavailable/i, body,
                 "expected an explicit chart error state")
    refute_includes body, "Type 2 diabetes mellitus", "clinical sections must not render on load failure"
    refute_includes body, "Lisinopril 10mg"
    assert_empty_banner!
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
