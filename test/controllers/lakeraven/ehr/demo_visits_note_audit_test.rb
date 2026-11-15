# frozen_string_literal: true

require "test_helper"
require "digest"
require_relative "../../../support/consent_write_test_helper"

# lakeraven-ehr#960: the demo visit's note action signs through
# ProgressNoteService, so it leaves the same signing AuditEvent. The posted
# note_text becomes body rows through the demo note gateway's fetch_body.
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
    assert_equal "progress_note_signed; patient #{DFN}; " \
                 "content-sha256 #{Digest::SHA256.hexdigest(NOTE_ROWS.join("\n"))}; content-rows 3",
                 event.outcome_desc
    event.attributes.each_value do |value|
      refute_includes value.to_s, SIGNATURE_CODE
      NOTE_ROWS.each { |row| refute_includes value.to_s, row }
    end
  end

  private

  def note_event_ids
    Lakeraven::EHR::AuditEvent.where(entity_type: "DocumentReference").pluck(:id)
  end
end
