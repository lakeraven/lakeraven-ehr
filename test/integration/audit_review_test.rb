# frozen_string_literal: true

require "test_helper"

# An audit log only a developer can read is not reviewable. §164.308(a)(1)(ii)(D)
# expects someone in compliance to be able to ask it questions — who touched
# this chart, what did this person do last Tuesday, what was refused — without
# filing a ticket.
class AuditReviewTest < ActionDispatch::IntegrationTest
  REVIEWER_KEY = "SYNTHETIC AUDIT REVIEW"

  setup do
    Lakeraven::EHR::AuditEvent.delete_all
    Lakeraven::EHR.configure { |c| c.audit_review_security_keys = [ REVIEWER_KEY ] }
  end

  teardown { Lakeraven::EHR.reset_configuration! }

  def sign_in_reviewer(keys: [ REVIEWER_KEY ])
    post "/lakeraven-ehr/test_session", params: { duz: "77001", user_type: "case_manager", security_keys: keys }
  end

  def seed_events
    Lakeraven::EHR::AuditEvent.create!(
      event_type: "rest", action: "R", outcome: "0", entity_type: "Patient",
      entity_identifier: "1", agent_who_type: "Practitioner", agent_who_identifier: "301",
      agent_name: "PROVIDER,TEST"
    )
    Lakeraven::EHR::AuditEvent.create!(
      event_type: "rest", action: "U", outcome: "4", entity_type: "Observation",
      entity_identifier: "9", agent_who_type: "Practitioner", agent_who_identifier: "302",
      outcome_desc: "Insufficient scope for writing Observation"
    )
  end

  # -- it is reachable, and it answers questions ---------------------------

  test "a reviewer can list accesses" do
    seed_events
    sign_in_reviewer

    get "/lakeraven-ehr/audit-review"

    assert_response :success
    assert_match "301", response.body
    assert_match "302", response.body
  end

  test "a reviewer can narrow by who, by what, and by refusal" do
    seed_events
    sign_in_reviewer

    get "/lakeraven-ehr/audit-review", params: { agent: "301" }
    assert_match "301", response.body
    refute_match "302", response.body

    get "/lakeraven-ehr/audit-review", params: { entity: "9" }
    assert_match "302", response.body
    refute_match "PROVIDER,TEST", response.body

    get "/lakeraven-ehr/audit-review", params: { outcome: "4" }
    assert_match "Insufficient scope", response.body
  end

  test "a reviewer can take the results away as CSV" do
    seed_events
    sign_in_reviewer

    get "/lakeraven-ehr/audit-review.csv"

    assert_response :success
    assert_match "text/csv", response.media_type
    assert_match "agent_who_identifier", response.body
    assert_match "301", response.body
  end

  # The reviewer is told how much the tamper-evidence is worth, rather than
  # left to assume the stronger answer.
  test "the review surface reports the integrity posture and names unverified rows" do
    seed_events
    sign_in_reviewer

    get "/lakeraven-ehr/audit-review/integrity"

    assert_response :success
    assert_match(/SHA-?256/i, response.body)
  end

  # -- it is not a back door ----------------------------------------------

  test "an unauthenticated visitor gets nowhere, and the attempt is recorded" do
    seed_events
    before = Lakeraven::EHR::AuditEvent.count

    get "/lakeraven-ehr/audit-review"

    assert_response :redirect
    assert_operator Lakeraven::EHR::AuditEvent.count, :>, before,
      "an attempt to read the audit log left no trace"
  end

  test "a signed-in user without the reviewer key is refused, and told why" do
    seed_events
    sign_in_reviewer(keys: [ "SOME OTHER KEY" ])

    get "/lakeraven-ehr/audit-review"

    assert_response :forbidden
    refute_match "PROVIDER,TEST", response.body, "the refusal disclosed the log it was refusing"

    event = Lakeraven::EHR::AuditEvent.order(:id).last
    assert_equal "AuditEvent", event.entity_type
    assert_match(/audit review/i, event.outcome_desc.to_s)
  end

  # An empty reviewer-key list is not "no restriction". Inventing a default
  # key name would open the log to whatever that name happens to mean at a
  # real site.
  test "with no reviewer key configured nobody gets in" do
    Lakeraven::EHR.configure { |c| c.audit_review_security_keys = [] }
    seed_events
    sign_in_reviewer

    get "/lakeraven-ehr/audit-review"

    assert_response :forbidden
    assert_match(/not configured/i, response.body)
  end

  # Reviewing the log is itself an access to who-saw-what.
  test "reading the audit log is itself audited" do
    seed_events
    sign_in_reviewer
    before = Lakeraven::EHR::AuditEvent.count

    get "/lakeraven-ehr/audit-review"

    review_event = Lakeraven::EHR::AuditEvent.order(:id).last
    assert_operator Lakeraven::EHR::AuditEvent.count, :>, before
    assert_equal "AuditEvent", review_event.entity_type
    assert_equal "77001", review_event.agent_who_identifier,
      "the review was filed under something other than the human who did it"
  end
end
