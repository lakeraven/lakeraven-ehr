# frozen_string_literal: true

require "test_helper"
require_relative "../support/url_patient_context_test_helper"
require_relative "../support/sensitive_patient_access_seeds"

# Sensitive-patient access on opening a record (#613, first slice).
#
# BPRM 6.0 checks DG SECURITY every time a record is opened. Here the open is
# POST /patients/:dfn/context (PatientContextsController#create), and it asks
# RPMS first: DG SENSITIVE RECORD ACCESS (PTSEC^DGSEC4), through
# RpmsRpc::DgSensitive.check_access. The answer decides the open:
#
#   0        not sensitive: opens as before, nothing more is sent
#   1        warning, no acknowledgement needed: opens; PTSEC logged the access
#   2        the user must acknowledge RPMS's warning first; acknowledging sends
#            DG SENSITIVE RECORD BULLETIN action 3 (DG SECURITY LOG entry and
#            bulletin), and only its "1" opens the record
#   3, 4, 5  denied
#   anything else, no answer, or an error: not opened. An absent answer is
#            never "not sensitive".
#
# RPMS is the mock, seeded with wire reply lines so the gem's parser runs
# (SensitivePatientAccessSeeds). Synthetic patients only: DFN 1 and DFN 3 of
# the baseline seeds.
class SensitivePatientAccessTest < ActionDispatch::IntegrationTest
  include UrlPatientContextTestHelper
  include SensitivePatientAccessSeeds

  AuditEvent = Lakeraven::EHR::AuditEvent
  PLAIN_DFN = "1"
  SENSITIVE_DFN = "3"
  # What the baseline seeds hold for DFN 3 (test/test_helper.rb). None of it
  # belongs on a page shown before the user may see the record.
  SENSITIVE_PATIENT_DETAILS = [
    /\bDOE\b/i, /\bJANE\b/i, /555667777/, /555-66-7777/, /1990/, /12\/25/, /Dec(ember)? 25/i
  ].freeze
  DENIAL_MESSAGES = {
    3 => [ "Access to your own record is not allowed." ],
    4 => [ "Your SSN is not defined: access to patient records is denied." ],
    5 => [ "Access to this record is restricted." ]
  }.freeze
  FAIL_CLOSED_STATUSES = [ 403, 503 ].freeze

  setup do
    enable_forgery_protection!
    sign_in_clinician!
    csrf_token # scraped before the audit log is cleared: one row per open below
    AuditEvent.delete_all
  end

  teardown do
    restore_forgery_protection!
    teardown_oauth!
    AuditEvent.delete_all
  end

  # -- 0: not sensitive ------------------------------------------------------

  test "a record RPMS says is not sensitive opens after the check, with no warning and no bulletin" do
    seed_not_sensitive!(PLAIN_DFN)

    post_open(PLAIN_DFN)

    assert_opened!(PLAIN_DFN)
    assert_checked_once!(PLAIN_DFN)
    assert_no_bulletin!
    assert_open_audited_as_success!(PLAIN_DFN)
  end

  # -- 1: warning, no acknowledgement needed (the silent path) ----------------

  test "a record the user may see without acknowledging opens silently: no warning page, no bulletin" do
    seed_sensitive_access!(SENSITIVE_DFN, 1, WARNING_LINES)

    post_open(SENSITIVE_DFN)

    assert_opened!(SENSITIVE_DFN)
    assert_checked_once!(SENSITIVE_DFN)
    assert_no_bulletin! # PTSEC^DGSEC4 wrote the DG SECURITY LOG entry itself
    assert_open_audited_as_success!(SENSITIVE_DFN)
  end

  # -- 2: the user must acknowledge ------------------------------------------

  test "a sensitive record does not open until the user acknowledges RPMS's warning" do
    seed_sensitive_access!(SENSITIVE_DFN, 2, WARNING_LINES)

    post_open(SENSITIVE_DFN)

    # 403, as the existing "this record is not open in your session" page is:
    # the record was not opened, and the audit row says so without new columns.
    assert_response :forbidden
    assert_not_opened!
    assert_checked_once!(SENSITIVE_DFN)
    assert_no_bulletin!
    assert_refusal_audited!(SENSITIVE_DFN)
  end

  test "the warning page shows RPMS's own lines, escaped, and a form that posts the acknowledgement back" do
    seed_sensitive_access!(SENSITIVE_DFN, 2, WARNING_LINES)

    post_open(SENSITIVE_DFN)

    assert_response :forbidden
    WARNING_LINES.each do |line|
      assert_includes response.body, ERB::Util.html_escape(line.strip), "RPMS warning line missing: #{line.inspect}"
    end
    assert_includes response.body, "Privacy Act of 1974 &amp; Health Insurance"
    form = acknowledgement_form
    assert form, "expected a form posting to #{context_path(SENSITIVE_DFN)}"
    assert_equal "post", form["method"].to_s.downcase
    assert_nil form.at_css("input[name='_method']"), "the acknowledgement is a plain POST"
    assert_equal "1", form.at_css("input[name='acknowledge_sensitive']")&.[]("value")
    assert form.at_css("input[name='authenticity_token']"), "the acknowledgement form carries a CSRF token"
  end

  test "the warning page carries no patient details: the dfn and RPMS's text only" do
    seed_sensitive_access!(SENSITIVE_DFN, 2, WARNING_LINES)

    post_open(SENSITIVE_DFN)

    assert_response :forbidden
    assert acknowledgement_form, "expected the warning page"
    SENSITIVE_PATIENT_DETAILS.each do |detail|
      refute_match detail, response.body, "the warning page must not show patient details (#{detail.inspect})"
    end
    banner = Nokogiri::HTML(response.body).at_css("#patient-banner")
    assert banner.at_css("form#patient-search"), "no patient is open: the bar is the search" if banner
  end

  test "RPMS message lines are escaped, never rendered as markup" do
    hostile = [ "<script>alert('dg')</script>", "<b>RESTRICTED</b> & \"tracked\"" ]
    seed_sensitive_access!(SENSITIVE_DFN, 2, hostile)

    post_open(SENSITIVE_DFN)

    assert_response :forbidden
    assert acknowledgement_form, "expected the warning page"
    refute_includes response.body, "<script>alert('dg')</script>"
    refute_includes response.body, "<b>RESTRICTED</b>"
    assert_includes response.body, "&lt;script&gt;alert("
    assert_includes response.body, "&lt;b&gt;RESTRICTED&lt;/b&gt; &amp; "
  end

  test "acknowledging checks again, writes the security log entry and bulletin, then opens the record" do
    seed_sensitive_access!(SENSITIVE_DFN, 2, WARNING_LINES)
    seed_sensitive_bulletin!(SENSITIVE_DFN, true)

    post_open(SENSITIVE_DFN, acknowledge: true)

    assert_opened!(SENSITIVE_DFN)
    assert_checked_once!(SENSITIVE_DFN) # in this request: the acknowledgement alone is not trusted
    assert_equal [ [ SENSITIVE_DFN, OPTION, LOG_AND_SEND ] ], sensitive_bulletin_calls.map { |c| c[:params].to_a },
                 "DG SENSITIVE RECORD BULLETIN is sent once: DFN, option, action 3"
    rpcs = RpmsRpc.client.received_calls.map { |c| c[:rpc] }
    assert_operator rpcs.index(ACCESS_RPC), :<, rpcs.index(BULLETIN_RPC), "the check comes before the bulletin"
    assert_open_audited_as_success!(SENSITIVE_DFN)
  end

  test "warning, then the page's own acknowledgement form, opens the record" do
    seed_sensitive_access!(SENSITIVE_DFN, 2, WARNING_LINES)
    seed_sensitive_bulletin!(SENSITIVE_DFN, true)

    post_open(SENSITIVE_DFN)
    assert_response :forbidden
    assert_not_opened!
    form = acknowledgement_form
    assert form, "expected the warning page's acknowledgement form"
    fields = form.css("input[name]").to_h { |input| [ input["name"], input["value"] ] }

    post form["action"], params: fields

    assert_opened!(SENSITIVE_DFN)
    assert_equal 2, sensitive_access_calls.size, "the check runs on the first open and again on the acknowledgement"
    assert_equal 1, sensitive_bulletin_calls.size
  end

  test "an acknowledged open does not happen when RPMS does not answer the bulletin" do
    seed_sensitive_access!(SENSITIVE_DFN, 2, WARNING_LINES)
    # no bulletin reply seeded: RpmsRpc::DgSensitive.record_bulletin reads nil

    post_open(SENSITIVE_DFN, acknowledge: true)

    assert_failed_closed!(SENSITIVE_DFN)
    assert_equal 1, sensitive_bulletin_calls.size, "the bulletin was attempted"
  end

  test "an acknowledged open does not happen when RPMS answers that the bulletin was not sent" do
    seed_sensitive_access!(SENSITIVE_DFN, 2, WARNING_LINES)
    seed_sensitive_bulletin!(SENSITIVE_DFN, false)

    post_open(SENSITIVE_DFN, acknowledge: true)

    assert_failed_closed!(SENSITIVE_DFN)
    assert_equal 1, sensitive_bulletin_calls.size, "the bulletin was attempted"
  end

  test "an acknowledged open does not happen when the bulletin call raises" do
    seed_sensitive_access!(SENSITIVE_DFN, 2, WARNING_LINES)
    raised = rpms_raises_on!(BULLETIN_RPC)

    post_open(SENSITIVE_DFN, acknowledge: true)

    assert_equal 1, raised.size, "the bulletin was sent, and raised"
    assert_failed_closed!(SENSITIVE_DFN)
  end

  test "an unacknowledged attempt on a sensitive record does not switch the session to it" do
    seed_not_sensitive!(PLAIN_DFN)
    seed_sensitive_access!(SENSITIVE_DFN, 2, WARNING_LINES)
    post_open(PLAIN_DFN)
    assert_equal PLAIN_DFN, session_open_patient_dfn

    post_open(SENSITIVE_DFN)

    assert_response :forbidden
    refute_equal SENSITIVE_DFN, session_open_patient_dfn
    assert_no_bulletin!
  end

  # -- The acknowledgement parameter is never trusted on its own --------------

  test "an acknowledgement posted for a record that is not sensitive opens it and sends no bulletin" do
    seed_not_sensitive!(PLAIN_DFN)

    post_open(PLAIN_DFN, acknowledge: true)

    assert_opened!(PLAIN_DFN)
    assert_checked_once!(PLAIN_DFN)
    assert_no_bulletin!
  end

  test "an acknowledgement posted on the silent path opens the record and sends no bulletin" do
    seed_sensitive_access!(SENSITIVE_DFN, 1, WARNING_LINES)

    post_open(SENSITIVE_DFN, acknowledge: true)

    assert_opened!(SENSITIVE_DFN)
    assert_checked_once!(SENSITIVE_DFN)
    assert_no_bulletin!
  end

  # -- 3, 4, 5: denied --------------------------------------------------------

  DENIAL_MESSAGES.each do |code, messages|
    test "access code #{code} is denied: 403, RPMS's message shown, not opened, no bulletin" do
      seed_sensitive_access!(SENSITIVE_DFN, code, messages)

      post_open(SENSITIVE_DFN)

      assert_response :forbidden
      assert_not_opened!
      assert_checked_once!(SENSITIVE_DFN)
      messages.each { |line| assert_includes response.body, ERB::Util.html_escape(line) }
      assert_nil acknowledgement_form, "a denied record offers no acknowledgement"
      assert_no_bulletin!
      assert_refusal_audited!(SENSITIVE_DFN)
    end

    test "access code #{code} stays denied when an acknowledgement is posted" do
      seed_sensitive_access!(SENSITIVE_DFN, code, messages)
      seed_sensitive_bulletin!(SENSITIVE_DFN, true)

      post_open(SENSITIVE_DFN, acknowledge: true)

      assert_response :forbidden
      assert_not_opened!
      assert_checked_once!(SENSITIVE_DFN)
      assert_no_bulletin!
      assert_refusal_audited!(SENSITIVE_DFN)
    end
  end

  # -- No usable answer: fail closed ------------------------------------------

  test "a record does not open when RPMS does not answer the sensitive-record check" do
    clear_sensitive_access!(PLAIN_DFN) # the mock's "" for an unseeded RPC: check_access reads nil

    post_open(PLAIN_DFN)

    assert_failed_closed!(PLAIN_DFN)
    assert_checked_once!(PLAIN_DFN)
  end

  test "an acknowledgement does not open a record whose check RPMS did not answer" do
    clear_sensitive_access!(SENSITIVE_DFN)
    seed_sensitive_bulletin!(SENSITIVE_DFN, true)

    post_open(SENSITIVE_DFN, acknowledge: true)

    assert_failed_closed!(SENSITIVE_DFN)
    assert_checked_once!(SENSITIVE_DFN)
  end

  {
    "the routine's error code -1" => [ "-1", "Required variable missing." ],
    "a code PTSEC does not define (7)" => [ "7" ],
    "a reply that is not a code" => [ "M ERROR: <UNDEFINED>PTSEC+3^DGSEC4" ]
  }.each do |label, lines|
    test "a record does not open on #{label}" do
      seed_access_reply!(PLAIN_DFN, lines)

      post_open(PLAIN_DFN)

      assert_failed_closed!(PLAIN_DFN)
      assert_checked_once!(PLAIN_DFN)
    end

    test "an acknowledgement does not open a record on #{label}" do
      seed_access_reply!(PLAIN_DFN, lines)
      seed_sensitive_bulletin!(PLAIN_DFN, true)

      post_open(PLAIN_DFN, acknowledge: true)

      assert_failed_closed!(PLAIN_DFN)
    end
  end

  test "a record does not open when the sensitive-record check raises" do
    seed_not_sensitive!(PLAIN_DFN)
    raised = rpms_raises_on!(ACCESS_RPC)

    post_open(PLAIN_DFN)

    assert_equal 1, raised.size, "the check was sent, and raised"
    assert_failed_closed!(PLAIN_DFN)
  end

  # Patient.canonical_dfn reads "03" as record 3. Whether the open canonicalizes
  # before the check or RPMS refuses the id, a sensitive record's leading-zero
  # form is not a way round the warning.
  test "a leading-zero form of a sensitive record's id does not open it unacknowledged" do
    seed_sensitive_access!(SENSITIVE_DFN, 2, WARNING_LINES)

    post_open("0#{SENSITIVE_DFN}")

    assert_not_opened!
    refute response.redirect?, "expected no redirect, got one to #{response.location}"
    assert_no_bulletin!
  end

  # -- A refused open of the record already open closes it (r1) ---------------
  #
  # RPMS is asked on every open. When it now refuses the record the session
  # holds, the session must stop holding it: every session-authenticated read
  # trusts that context, and RPMS has just said no. Each block runs in the test.

  REFUSED_REOPENS = {
    "denies it (code 3)" => proc do
      seed_sensitive_access!(SENSITIVE_DFN, 3, DENIAL_MESSAGES.fetch(3))
      post_open(SENSITIVE_DFN)
      assert_response :forbidden
    end,
    "asks for an acknowledgement that is not given (code 2)" => proc do
      seed_sensitive_access!(SENSITIVE_DFN, 2, WARNING_LINES)
      post_open(SENSITIVE_DFN)
      assert_response :forbidden
      assert acknowledgement_form, "expected the warning page"
    end,
    "answers that the acknowledged bulletin was not sent" => proc do
      seed_sensitive_access!(SENSITIVE_DFN, 2, WARNING_LINES)
      seed_sensitive_bulletin!(SENSITIVE_DFN, false)
      post_open(SENSITIVE_DFN, acknowledge: true)
      assert_equal 1, sensitive_bulletin_calls.size, "the bulletin was attempted"
      assert_includes FAIL_CLOSED_STATUSES, response.status
    end,
    "does not answer the check" => proc do
      clear_sensitive_access!(SENSITIVE_DFN)
      post_open(SENSITIVE_DFN)
      assert_includes FAIL_CLOSED_STATUSES, response.status
    end,
    "raises on the check" => proc do
      raised = rpms_raises_on!(ACCESS_RPC)
      post_open(SENSITIVE_DFN)
      assert_equal 1, raised.size, "the check was sent, and raised"
      assert_includes FAIL_CLOSED_STATUSES, response.status
    end
  }.freeze

  REFUSED_REOPENS.each do |label, refused_reopen|
    test "re-opening the record already open closes it when RPMS now #{label}" do
      open_not_sensitive!(SENSITIVE_DFN)

      instance_exec(&refused_reopen)

      refute response.redirect?, "the re-open is refused, not redirected to #{response.location}"
      assert_not_opened!
      assert_refusal_audited!(SENSITIVE_DFN)
    end
  end

  test "a refused re-open closes the open record when the session holds its leading-zero form" do
    open_not_sensitive!("0#{SENSITIVE_DFN}", record: SENSITIVE_DFN)
    seed_sensitive_access!(SENSITIVE_DFN, 3, DENIAL_MESSAGES.fetch(3))

    post_open(SENSITIVE_DFN)

    assert_response :forbidden
    assert_not_opened! # "03" and "3" are the same record
  end

  test "a refused re-open by its leading-zero form closes the record the session holds as the plain id" do
    open_not_sensitive!(SENSITIVE_DFN)
    seed_sensitive_access!(SENSITIVE_DFN, 3, DENIAL_MESSAGES.fetch(3))

    post_open("0#{SENSITIVE_DFN}")

    refute response.redirect?, "expected no redirect, got one to #{response.location}"
    assert_not_opened!
  end

  REFUSED_REOPENS.each do |label, refused_open|
    test "a different open record stays open when RPMS #{label} for another patient" do
      open_not_sensitive!(PLAIN_DFN)

      instance_exec(&refused_open)

      refute response.redirect?
      assert_equal PLAIN_DFN, session_open_patient_dfn, "the refusal was about patient #{SENSITIVE_DFN}, not the open record"
    end
  end

  # -- The user cannot bind the option the check runs under (r1) --------------
  #
  # RPMS accepted the user's codes but does not give them OR CPRS GUI CHART:
  # the gem's ContextRefusedError (as sign-on raises it, #501). That is a
  # determined "no" about the account, not an outage: 403, and the page says
  # so instead of telling the user to try again.

  test "a user whose RPMS account cannot run the sensitive-record check is refused with 403 and told why" do
    seed_not_sensitive!(PLAIN_DFN)
    raised = rpms_raises_on!(ACCESS_RPC, error: RpmsRpc::Client::ContextRefusedError,
                                         message: "this user may not use #{OPTION}")

    post_open(PLAIN_DFN)

    assert_equal 1, raised.size, "the check was attempted, and refused"
    assert_response :forbidden
    assert_not_opened!
    assert_match(/RPMS account is not set up for the sensitive-record check/i, response.body)
    refute_match(/try again/i, response.body, "retrying does not fix an account that lacks the option")
    assert_nil acknowledgement_form
    assert_no_bulletin!
    assert_refusal_audited!(PLAIN_DFN)
  end

  test "an acknowledgement does not open a record for a user whose RPMS account cannot run the check" do
    seed_sensitive_bulletin!(SENSITIVE_DFN, true)
    raised = rpms_raises_on!(ACCESS_RPC, error: RpmsRpc::Client::ContextRefusedError,
                                         message: "this user may not use #{OPTION}")

    post_open(SENSITIVE_DFN, acknowledge: true)

    assert_equal 1, raised.size
    assert_response :forbidden
    assert_not_opened!
    refute_match(/try again/i, response.body)
    assert_no_bulletin!
    assert_refusal_audited!(SENSITIVE_DFN)
  end

  # -- Ordering: a caller who may not open the record never causes the check --
  #
  # PTSEC^DGSEC4 writes the DG SECURITY LOG. A request the open refuses for
  # its own reasons must not reach it.

  test "a POST without a CSRF token sends no sensitive-record check" do
    seed_sensitive_access!(SENSITIVE_DFN, 2, WARNING_LINES)

    post context_path(SENSITIVE_DFN), params: { acknowledge_sensitive: "1" }

    assert_response :unprocessable_entity # InvalidAuthenticityToken
    assert_not_opened!
    assert_empty sensitive_access_calls, "DG SENSITIVE RECORD ACCESS must not be sent"
    assert_no_bulletin!
  end

  test "a POST from a session that is not signed in sends no sensitive-record check" do
    seed_sensitive_access!(SENSITIVE_DFN, 2, WARNING_LINES)
    reset! # a new browser: no session
    @csrf_token = nil

    post context_path(SENSITIVE_DFN), params: { authenticity_token: csrf_token, acknowledge_sensitive: "1" }

    assert_response :unauthorized
    assert_not_opened!
    assert_empty sensitive_access_calls, "DG SENSITIVE RECORD ACCESS must not be sent"
    assert_no_bulletin!
  end

  test "a token with neither Patient nor screening read scope sends no sensitive-record check" do
    seed_sensitive_access!(SENSITIVE_DFN, 2, WARNING_LINES)
    sign_in_clinician!(scopes: "user/AllergyIntolerance.read")

    post_open(SENSITIVE_DFN, acknowledge: true)

    assert_response :forbidden
    assert_not_opened!
    assert_nil acknowledgement_form
    assert_empty sensitive_access_calls, "DG SENSITIVE RECORD ACCESS must not be sent"
    assert_no_bulletin!
  end

  test "a patient-scoped token for another patient sends no sensitive-record check" do
    seed_sensitive_access!(SENSITIVE_DFN, 2, WARNING_LINES)
    reset! # the patient app is not the clinician's browser
    @csrf_token = nil

    post context_path(SENSITIVE_DFN),
         params: { authenticity_token: csrf_token, acknowledge_sensitive: "1" },
         headers: patient_bound_chart_headers(patient_dfn: PLAIN_DFN)

    assert_response :forbidden
    assert_includes response.body, "Patient context mismatch"
    assert_not_opened!
    assert_empty sensitive_access_calls, "DG SENSITIVE RECORD ACCESS must not be sent"
    assert_no_bulletin!
  end

  private

  def context_path(dfn) = "#{MOUNT}/patients/#{dfn}/context"

  def post_open(dfn, acknowledge: false)
    params = { authenticity_token: csrf_token }
    params[:acknowledge_sensitive] = "1" if acknowledge
    post context_path(dfn), params: params
  end

  # The warning page's form: posts to the open it came from, with the
  # acknowledgement. Nil when the page has none.
  def acknowledgement_form
    Nokogiri::HTML(response.body).css("form").find do |form|
      form["action"].to_s.end_with?(context_path(SENSITIVE_DFN)) &&
        form.at_css("input[name='acknowledge_sensitive']")
    end
  end

  # RPMS raises for one RPC, as a broker that drops the call does. The mock is
  # rebuilt before every test (GlobalStoreIsolation), so nothing to restore.
  def rpms_raises_on!(rpc_name, error: RpmsRpc::Client::RpcError, message: "broker dropped #{rpc_name}")
    raised = []
    RpmsRpc.client.define_singleton_method(:call_rpc) do |rpc, *params|
      if rpc == rpc_name
        raised << params
        raise error, message
      end
      super(rpc, *params)
    end
    raised
  end

  # The record is open in the session (RPMS answered 0), and the audit log
  # holds nothing of that open: one row per attempt below.
  def open_not_sensitive!(dfn, record: dfn)
    seed_not_sensitive!(record)
    post_open(dfn)
    assert_equal dfn, session_open_patient_dfn, "precondition: the record is open"
    RpmsRpc.client.received_calls.clear
    AuditEvent.delete_all
  end

  def assert_opened!(dfn)
    assert_redirected_to "#{MOUNT}/patients/#{dfn}"
    assert_equal dfn, session_open_patient_dfn
  end

  def assert_not_opened!
    assert_nil session_open_patient_dfn, "the record must not be open in the session"
  end

  # The check: once in this request, for the route's patient, under the
  # option the gem's wrapper scopes.
  def assert_checked_once!(dfn)
    calls = sensitive_access_calls
    assert_equal 1, calls.size, "expected one DG SENSITIVE RECORD ACCESS, got #{calls.size}"
    assert_equal dfn, calls.first[:params][0], "the check names the route's patient"
    assert_equal OPTION, calls.first[:params][2], "the check sends the option the open runs under"
  end

  def assert_no_bulletin!
    assert_empty sensitive_bulletin_calls, "DG SENSITIVE RECORD BULLETIN must not be sent"
  end

  # Not opened, no way on to the chart, no bulletin left behind as if the open
  # had happened, and an audit row that does not read as an open.
  def assert_failed_closed!(dfn)
    assert_includes FAIL_CLOSED_STATUSES, response.status, "expected the open to be refused, got #{response.status}"
    refute response.redirect?
    assert_not_opened!
    assert_nil acknowledgement_form, "nothing to acknowledge when RPMS gave no warning"
    assert_refusal_audited!(dfn)
  end

  def open_audit_rows(dfn)
    AuditEvent.where(action: "E", entity_type: "Patient", entity_identifier: dfn).order(:id).to_a
  end

  # As ScreeningsControllerTest reads it: an Execute on the patient, outcome 0.
  def assert_open_audited_as_success!(dfn)
    rows = open_audit_rows(dfn)
    assert_equal 1, rows.size, "one audit row per open"
    assert_equal "0", rows.first.outcome
  end

  # One row for the attempt, and it is not a success: outcome 4 or 8, with the
  # reason on the row (AuditableClinicalAccess#note_audit_denial).
  def assert_refusal_audited!(dfn)
    rows = open_audit_rows(dfn)
    assert_equal 1, rows.size, "one audit row per attempted open"
    refute_equal "0", rows.first.outcome, "an open that did not happen must not be audited as a success"
    assert_match(/sensitive/i, rows.first.outcome_desc.to_s, "the audit row says why the open was refused")
  end
end
