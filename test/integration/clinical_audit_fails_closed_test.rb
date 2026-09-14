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

  # -- exactly one row per request ----------------------------------------

  # A controller that mixes in both this concern and a fail-closed variant
  # would otherwise register the wrapper twice and record twice.
  test "one request produces exactly one audit row" do
    setup_auth(scopes: "system/*.read")

    get "/lakeraven-ehr/Observation", params: { patient: "1" }, headers: @headers

    assert_equal 1, Lakeraven::EHR::AuditEvent.count
  end

  private

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
