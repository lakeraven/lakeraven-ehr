# frozen_string_literal: true

require "test_helper"

# The audit log has to hold the events that matter most: the ones that were
# REFUSED, and the ones that changed something. It used to hold neither
# reliably.
class ClinicalAuditFailsClosedTest < ActionDispatch::IntegrationTest
  setup { Lakeraven::EHR::AuditEvent.delete_all }

  # -- refusals are recorded ----------------------------------------------

  # `record_audit_event` was an after_action, and Rails skips after-callbacks
  # when a before-callback halts the chain — so 200 wrote a row and 403/401
  # wrote nothing at all.
  test "a forbidden access is audited, with the reason" do
    setup_auth(scopes: "user/Patient.read")

    get "/lakeraven-ehr/Observation", params: { patient: "1" }, headers: @headers
    assert_response :forbidden

    event = Lakeraven::EHR::AuditEvent.order(:id).last
    refute_nil event, "a refused access left no audit trail"
    assert_equal "4", event.outcome
    assert_match(/insufficient scope/i, event.outcome_desc.to_s)
  end

  test "an unauthenticated access is audited" do
    get "/lakeraven-ehr/Observation", params: { patient: "1" }
    assert_response :unauthorized

    event = Lakeraven::EHR::AuditEvent.order(:id).last
    refute_nil event, "a rejected credential left no audit trail"
    assert_equal "4", event.outcome
  end

  # A rejected credential names nobody. Recording it under a shared identity
  # would be worse than recording it as unattributed.
  test "an unauthenticated access is recorded as unattributed, not misattributed" do
    get "/lakeraven-ehr/Observation", params: { patient: "1" }

    event = Lakeraven::EHR::AuditEvent.order(:id).last
    assert_equal "Unknown", event.agent_who_type
    assert_nil event.agent_who_identifier
  end

  test "a successful access is still audited" do
    setup_auth(scopes: "system/*.read")

    get "/lakeraven-ehr/Observation", params: { patient: "1" }, headers: @headers
    assert_response :ok

    event = Lakeraven::EHR::AuditEvent.order(:id).last
    refute_nil event
    assert_equal "0", event.outcome
    assert_equal @application.uid, event.agent_who_identifier
  end

  # -- an access that cannot be recorded is not completed ------------------

  test "a read whose audit cannot be written is refused, and discloses nothing" do
    setup_auth(scopes: "system/*.read")

    with_broken_audit do
      get "/lakeraven-ehr/Observation", params: { patient: "1" }, headers: @headers
    end

    assert_response :service_unavailable
    refute_includes response.body, "Anderson"
  end

  # THE ROUND-4 DEFECT in this pattern's first version: it recorded AFTER
  # `yield`, outside any transaction. By then the action's writes had already
  # committed, so a failed audit left a change in the database that nothing
  # could account for. The audit row and the action's writes now share one
  # transaction.
  #
  # Exercised against a representative audited writer in the dummy host app
  # (never shipped): no FHIR endpoint in the engine writes to the database
  # today, so an in-tree endpoint would make this test pass because nothing
  # was written — proving nothing. The property is not hypothetical; the
  # screening surface (#491) records QuestionnaireResponses.
  test "a write whose audit cannot be written leaves nothing behind" do
    setup_auth(scopes: "system/*.read system/*.write")
    before = Lakeraven::EHR::ReconciliationSession.count

    with_broken_audit { post "/audited_writer", params: { patient_dfn: "1" }, headers: @headers }

    assert_response :service_unavailable
    assert_equal before, Lakeraven::EHR::ReconciliationSession.count,
      "the action's write committed even though the access could not be recorded"
  end

  # The other half: the guard must not make audited writes impossible.
  test "a write whose audit succeeds does persist, with its audit row" do
    setup_auth(scopes: "system/*.read system/*.write")
    before = Lakeraven::EHR::ReconciliationSession.count

    post "/audited_writer", params: { patient_dfn: "1" }, headers: @headers

    assert_response :created
    assert_equal before + 1, Lakeraven::EHR::ReconciliationSession.count
    assert_equal 1, Lakeraven::EHR::AuditEvent.count
  end

  # The suite could not tell a joined transaction from a real one: Rails opens
  # the transactional-test wrapper with `joinable: false`, which silently
  # promotes any inner `transaction` to a savepoint. So the fail-closed
  # rollback "worked" in every test and would NOT have worked for a caller
  # that owns its own transaction — a service object wrapping a write, a
  # bulk importer. This test owns a joinable transaction, the way such a
  # caller does.
  test "an audited write inside a caller-owned transaction still rolls back when the audit fails" do
    setup_auth(scopes: "system/*.read system/*.write")
    before = Lakeraven::EHR::ReconciliationSession.count

    with_broken_audit do
      ActiveRecord::Base.transaction do
        post "/audited_writer", params: { patient_dfn: "1" }, headers: @headers
      end
    end

    assert_response :service_unavailable
    assert_equal before, Lakeraven::EHR::ReconciliationSession.count,
      "the write survived inside a caller-owned transaction, so the audit rollback was a no-op"
  end

  # -- a write is recorded as a write -------------------------------------

  # Everything was logged as a Read, so the log could not answer "what did
  # this person CHANGE" — the question a records request actually asks.
  test "a write is audited as a write, not a read" do
    setup_auth(scopes: "system/*.read system/*.write")

    post "/audited_writer", params: { patient_dfn: "1" }, headers: @headers
    assert_response :created

    event = Lakeraven::EHR::AuditEvent.order(:id).last
    assert_equal "C", event.action, "a create was recorded as a read"
  end

  # -- request input can never break the audit write (F2) ------------------

  # The entity validation is sound; feeding it raw request params was not:
  # a reference-shaped ?id= on a search made every row invalid, which the
  # fail-closed wrapper turned into a 503 with ZERO rows — any client could
  # 5xx every FHIR search by appending a param, and malformed-identifier
  # PROBES (exactly the §164.312(b) events) left no trace. The identifier is
  # OMITTED when it cannot name a record of the audited type: a row with no
  # entity beats no row, and never a row that lies.
  test "a reference-shaped query id cannot 503 a search or suppress its row" do
    setup_auth(scopes: "system/*.read")

    get "/lakeraven-ehr/Observation", params: { patient: "1", id: "Observation/9" }, headers: @headers

    assert_response :ok, "attacker-influencable input turned a working search into a 503"
    event = Lakeraven::EHR::AuditEvent.order(:id).last
    refute_nil event, "the probing request left no audit trail"
    assert_nil event.entity_identifier, "the malformed identifier was recorded as if real"
  end

  test "a non-DFN query id on a Patient search records a row, not a 503" do
    setup_auth(scopes: "system/*.read")

    get "/lakeraven-ehr/Patient", params: { id: "abc" }, headers: @headers

    assert_response :ok
    refute_nil Lakeraven::EHR::AuditEvent.order(:id).last,
      "the malformed-identifier probe left no audit trail"
  end

  # The determined 404 must stay a recorded 404: on main this probe got 404
  # plus a row; the first fail-closed version got 503 plus NO row — "we
  # determined no" rewritten as "we could not determine", unrecorded.
  test "a probe of a non-DFN Patient id is a recorded 404, not an unrecorded 503" do
    setup_auth(scopes: "system/*.read")

    get "/lakeraven-ehr/Patient/SR-DRAFT-001", headers: @headers

    assert_response :not_found
    event = Lakeraven::EHR::AuditEvent.order(:id).last
    refute_nil event, "the probe of a malformed Patient id left no audit trail"
    assert_equal "4", event.outcome
    assert_nil event.entity_identifier
    assert_match(/not found/i, event.outcome_desc.to_s)
  end

  # -- an access that raises is a failure, not a success -------------------

  # `audit_outcome` used to read `response.status`, which is still 200 when
  # the attempt is recorded on the exception path — so a raising access was
  # recorded as outcome "0" and the review screen showed it as a success,
  # while this concern had just rolled the action's writes back.
  test "an access that raises is recorded as a failure, not a success" do
    setup_auth(scopes: "system/*.read system/*.write")
    before = Lakeraven::EHR::ReconciliationSession.count

    assert_raises(AuditedWriterController::SyntheticActionFailure) do
      post "/audited_writer", params: { patient_dfn: "1", explode: "1" }, headers: @headers
    end

    event = Lakeraven::EHR::AuditEvent.order(:id).last
    refute_nil event, "a raising access left no audit trail"
    assert_equal "8", event.outcome, "a raising access was recorded as a success"
    assert_match(/SyntheticActionFailure/, event.outcome_desc.to_s,
      "the failure row does not say what failed")
    assert_equal before, Lakeraven::EHR::ReconciliationSession.count,
      "the raising action's write survived"
  end

  # (F3's second half — the failure row surviving a caller-owned
  #  transaction's rollback — lives in AuditFailureRowSurvivalTest, which
  #  opts out of the transactional wrapper; under the wrapper the pinned
  #  connection makes the detached write degrade to inline by design.)

  test "the failure row never carries the exception message" do
    setup_auth(scopes: "system/*.read system/*.write")

    assert_raises(AuditedWriterController::SyntheticActionFailure) do
      post "/audited_writer", params: { patient_dfn: "1", explode: "1" }, headers: @headers
    end

    event = Lakeraven::EHR::AuditEvent.order(:id).last
    refute_includes event.outcome_desc.to_s, "synthetic mid-action failure",
      "the exception MESSAGE reached the audit row — messages can carry PHI"
  end

  # -- a refusal discloses nothing ----------------------------------------

  # A sibling PR refused an access with 503 and the patient name still reached
  # the browser: not in the body, which was discarded, but in the FLASH, which
  # the 503 response carried out in the session cookie. Headers are the same
  # class of leak.
  test "a refused access discloses nothing in the body, the headers, or the flash" do
    setup_auth(scopes: "system/*.read")
    label = AuditedBrowserController::PATIENT_LABEL

    with_broken_audit { get "/audited_browser/1", headers: @headers }

    assert_response :service_unavailable
    refute_includes response.body, label, "the refusal disclosed the patient in its body"
    assert_nil response.headers["Location"], "the refusal kept the redirect it was refusing"
    assert_nil response.headers["X-Patient-Name"], "the refusal disclosed the patient in a header"
    refute_includes response.headers.to_h.values.join(" "), label,
      "the refusal disclosed the patient in a response header"
    assert_empty flash.to_h, "the refusal carried the patient out in the flash"
    refute_leaked_in_cookies label
  end

  # The gate proved the first version of this contract ESCAPING-BLIND: the
  # cookie read `Anderson%2CAlice`, so a `refute_includes` on "Anderson,Alice"
  # passed on a live leak. Every cookie assertion here DECODES first.
  test "a refused access discloses nothing through the cookie jar or the session" do
    setup_auth(scopes: "system/*.read")
    label = AuditedBrowserController::PATIENT_LABEL

    with_broken_audit { get "/audited_browser/1", headers: @headers }

    assert_response :service_unavailable
    refute_leaked_in_cookies label
    # The session cookie is opaque on the wire; the test-side `session`
    # helper reads it decrypted, which is what a browser replaying the cookie
    # would eventually surface.
    refute_includes session.to_hash.values.map(&:to_s).join(" "), label,
      "the refusal carried the patient out in the session"
  end

  # Adopted from the round-2 gate's probe (P5): the rollback must hold for
  # EVERY cookie-write path an action has, not just the plain jar —
  # signed/encrypted/permanent jars, a pending cookie DELETE (a delete is a
  # write), a raw Set-Cookie header, and response.set_cookie.
  test "a refused access leaks nothing through any cookie-write path" do
    setup_auth(scopes: "system/*.read")
    label = ProbeCookiesController::LABEL

    with_broken_audit { get "/probe_cookies/1", headers: @headers }

    assert_response :service_unavailable
    set_cookie = Array(response.headers["Set-Cookie"]).join("\n")
    refute_includes CGI.unescape(set_cookie), label, "a cookie path carried the patient out"
    %w[plain_patient signed_patient encrypted_patient permanent_patient
       raw_header_patient response_api_patient].each do |name|
      refute_includes set_cookie, name, "cookie #{name} survived the rollback"
    end
    refute_match(/preexisting_cookie=;/, set_cookie, "the pending cookie DELETE survived the rollback")
    refute_includes session.to_hash.values.map(&:to_s).join(" "), label
  end

  # The control that keeps the probe honest: on success those cookies ARE
  # written, so the refusal test above cannot pass vacuously.
  test "the cookie probe surface is live on the success path" do
    setup_auth(scopes: "system/*.read")

    get "/probe_cookies/1", headers: @headers

    assert_response :ok
    set_cookie = Array(response.headers["Set-Cookie"]).join("\n")
    %w[plain_patient signed_patient encrypted_patient raw_header_patient].each do |name|
      assert_includes set_cookie, name, "probe controller inert — the refusal test would be vacuous"
    end
  end

  # The rollback must not destroy session state the action did NOT write —
  # throwing away a clinician's sign-in on every audit outage would make the
  # 503 a logout button.
  test "refusing an unrecorded access preserves the pre-existing session" do
    post "/lakeraven-ehr/login", params: { username: "testprovider", password: "test" }
    assert_equal "99999", session[:duz]
    setup_auth(scopes: "system/*.read")

    with_broken_audit { get "/audited_browser/1", headers: @headers }

    assert_response :service_unavailable
    assert_equal "99999", session[:duz],
      "refusing an unrecorded access destroyed the signed-in session"
  end

  # -- exactly one row per request ----------------------------------------

  # A controller that mixes in both this concern and a fail-closed variant
  # would otherwise register the wrapper twice and record twice.
  test "one request produces exactly one audit row" do
    setup_auth(scopes: "system/*.read")

    get "/lakeraven-ehr/Observation", params: { patient: "1" }, headers: @headers

    assert_equal 1, Lakeraven::EHR::AuditEvent.count
  end

  private

  # Set-Cookie values are percent-encoded on the wire; comparing against the
  # raw header is how a live leak passes a refute. Decode EVERY cookie value
  # before asserting.
  def refute_leaked_in_cookies(label)
    set_cookie = Array(response.headers["Set-Cookie"]).join("\n")
    decoded = CGI.unescape(set_cookie)
    refute_includes decoded, label,
      "the refusal disclosed the patient in a Set-Cookie header (decoded: #{decoded.truncate(200)})"
    cookies.to_hash.each_value do |value|
      refute_includes CGI.unescape(value.to_s), label,
        "the refusal left the patient in the cookie jar"
    end
  end

  def setup_auth(scopes:)
    @application = Doorkeeper::Application.create!(
      name: "client-#{SecureRandom.hex(4)}", redirect_uri: "https://example.test/cb",
      scopes: scopes, confidential: true
    )
    token = Doorkeeper::AccessToken.create!(
      application: @application, scopes: scopes, expires_in: 3600
    )
    @headers = { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }
  end

  # Make the audit insert fail the way a full disk or a locked table would.
  # Defined directly on the singleton so it can actually be removed again —
  # a prepended module cannot, and leaving it in place breaks every later
  # test in the process.
  def with_broken_audit
    Lakeraven::EHR::AuditEvent.define_singleton_method(:create!) do |*|
      raise ActiveRecord::StatementInvalid, "audit store unavailable"
    end
    yield
  ensure
    Lakeraven::EHR::AuditEvent.singleton_class.send(:remove_method, :create!)
  end
end
