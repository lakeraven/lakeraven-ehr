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

  # (The integrity screen is Part 2 of the #507 split, tested there; this
  #  branch links to it only when its route exists — see the index view.)

  # -- the CSV is COMPLETE, not silently truncated (S10) ------------------

  # The screen tells a reviewer to download the CSV for the records beyond
  # the 200-row page. The first version capped the CSV at 10,000 rows with
  # no marker, so a compliance report could omit matching accesses in
  # silence. The export must contain every matching row.
  test "the CSV export contains every matching row, not a silent cap" do
    sign_in_reviewer
    count = 10_050
    rows = Array.new(count) do |i|
      {
        event_type: "rest", action: "R", outcome: "0", entity_type: "Patient",
        entity_identifier: "1", agent_who_type: "Practitioner",
        agent_who_identifier: "301", created_at: Time.current
      }
    end
    Lakeraven::EHR::AuditEvent.insert_all!(rows)

    get "/lakeraven-ehr/audit-review.csv"
    assert_response :success

    data_lines = response.body.each_line.count - 1 # minus header
    # The export row itself is filtered out by entity_identifier; count the
    # Patient reads we seeded.
    patient_rows = response.body.each_line.count { |l| l.include?(",Patient,1,") }
    assert_operator patient_rows, :>=, count,
      "the CSV truncated a #{count}-row result to #{patient_rows} with no marker"
  end

  # An export is a DIFFERENT act from opening the screen: "who took the log
  # away" is worth distinguishing from "who looked at it".
  test "a CSV export is recorded as an export, distinct from opening the screen" do
    seed_events
    sign_in_reviewer

    get "/lakeraven-ehr/audit-review.csv"
    assert_response :success

    export_row = Lakeraven::EHR::AuditEvent.where(event_type: "export").order(:id).last
    refute_nil export_row, "a CSV export was indistinguishable from opening the screen"
    assert_match(/export/i, export_row.outcome_desc.to_s)
    assert_equal "77001", export_row.agent_who_identifier
  end

  # Fail closed: if the export's own audit row cannot be written, the log is
  # not handed over.
  test "a CSV export whose audit cannot be written is refused" do
    seed_events
    sign_in_reviewer

    Lakeraven::EHR::AuditEvent.define_singleton_method(:create!) do |*|
      raise ActiveRecord::StatementInvalid, "audit store unavailable"
    end
    begin
      get "/lakeraven-ehr/audit-review.csv"
    ensure
      Lakeraven::EHR::AuditEvent.singleton_class.send(:remove_method, :create!)
    end

    assert_response :service_unavailable
    refute_match "PROVIDER,TEST", response.body, "the unrecorded export served the log anyway"
  end

  # -- the review's own row names a record it actually touched (S11) ------

  # The review row must not claim a patient entity — it read the log, not a
  # chart. A row filed as Patient/nil (or Patient/<something>) here would
  # surface as a phantom access under §164.528.
  test "the review's own audit row carries no patient entity" do
    seed_events
    sign_in_reviewer

    get "/lakeraven-ehr/audit-review"

    review_row = Lakeraven::EHR::AuditEvent.where(entity_type: "AuditEvent").order(:id).last
    refute_nil review_row
    assert_nil review_row.entity_identifier,
      "the review row claimed to touch a specific record"
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
