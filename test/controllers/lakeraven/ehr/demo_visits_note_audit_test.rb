# frozen_string_literal: true

require "test_helper"
require "digest"
require_relative "../../../support/consent_write_test_helper"

# lakeraven-ehr#960: the demo visit's note action signs through
# ProgressNoteService, so it leaves the same signing AuditEvent. The posted
# note_text becomes body rows through the demo note gateway's fetch_body. The
# demo gateway's body does not change on signing, so the record hash and row
# count equal the content ones.
class DemoVisitsNoteAuditTest < ActionDispatch::IntegrationTest
  # Only for with_demo_visits_gate_open. The module defines no setup or
  # teardown hooks, so including it signs nobody in and writes no consent.
  include ConsentWriteTestHelper

  DFN = "3"
  NOTE_PATH = "/lakeraven-ehr/patients/#{DFN}/visit/note"
  SIGNATURE_CODE = "SIGSECRET42"
  NOTE_ROWS = [
    "S: Synthetic demo complaint.",
    "O: Synthetic demo finding.",
    "P: Synthetic demo plan."
  ].freeze
  NOTE_TEXT = NOTE_ROWS.join("\n")

  test "posting a signed note writes one DocumentReference audit event with a success outcome" do
    before = note_event_ids

    with_demo_visits_gate_open do
      post NOTE_PATH, params: { note_text: NOTE_TEXT, signature_code: SIGNATURE_CODE }
    end

    assert_response :redirect
    written = Lakeraven::EHR::AuditEvent.where(entity_type: "DocumentReference").where.not(id: before).to_a
    assert_equal 1, written.size, "expected exactly one signing AuditEvent, got #{written.size}"
    event = written.first
    assert_equal "0", event.outcome
    assert_equal "E", event.action
    assert_equal Lakeraven::EHR::DemoVisitsController::AUTHOR_DUZ.to_s, event.agent_who_identifier
    note_hash = Digest::SHA256.hexdigest(NOTE_ROWS.join("\n"))
    assert_includes event.outcome_desc, "record-sha256"
    assert_includes event.outcome_desc, "record-rows"
    assert_equal "progress_note_signed; patient #{DFN}; content-sha256 #{note_hash}; content-rows 3; " \
                 "record-sha256 #{note_hash}; record-rows 3",
                 event.outcome_desc
    event.attributes.each_value do |value|
      refute_includes value.to_s, SIGNATURE_CODE
      NOTE_ROWS.each { |row| refute_includes value.to_s, row }
    end
  end

  # A browser posts a textarea with CRLF row ends. The demo gateway splits on
  # CRLF, CR or LF, so the same note hashes the same however it was posted.
  { "CRLF" => "\r\n", "CR" => "\r" }.each do |name, separator|
    test "a note posted with #{name} row ends records the same content hash and row count as one posted with LF" do
      lf = signed_note_event(NOTE_ROWS.join("\n"))
      other = signed_note_event(NOTE_ROWS.join(separator))

      expected = "content-sha256 #{Digest::SHA256.hexdigest(NOTE_ROWS.join("\n"))}; content-rows 3"
      assert_includes lf.outcome_desc, expected
      assert_includes other.outcome_desc, expected
      assert_equal lf.outcome_desc, other.outcome_desc
    end
  end

  private

  # Posts the note and returns the one signing AuditEvent it wrote.
  def signed_note_event(note_text)
    before = note_event_ids
    with_demo_visits_gate_open do
      post NOTE_PATH, params: { note_text: note_text, signature_code: SIGNATURE_CODE }
    end
    assert_response :redirect
    written = Lakeraven::EHR::AuditEvent.where(entity_type: "DocumentReference").where.not(id: before).to_a
    assert_equal 1, written.size, "expected exactly one signing AuditEvent, got #{written.size}"
    assert_equal "0", written.first.outcome
    written.first
  end

  def note_event_ids
    Lakeraven::EHR::AuditEvent.where(entity_type: "DocumentReference").pluck(:id)
  end
end
