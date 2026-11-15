# frozen_string_literal: true

require "test_helper"

# lakeraven-ehr#960: the demo visit's note action signs through
# ProgressNoteService, so it leaves the same signing AuditEvent.
class DemoVisitsNoteAuditTest < ActionDispatch::IntegrationTest
  DFN = "3"
  NOTE_PATH = "/lakeraven-ehr/patients/#{DFN}/visit/note"
  SIGNATURE_CODE = "SIGSECRET42"
  NOTE_TEXT = "S: Synthetic demo complaint.\nP: Synthetic demo plan."

  test "posting a signed note writes one DocumentReference audit event with a success outcome" do
    with_demo_visits_gate_open do
      assert_difference -> { Lakeraven::EHR::AuditEvent.where(entity_type: "DocumentReference").count }, 1 do
        post NOTE_PATH, params: { note_text: NOTE_TEXT, signature_code: SIGNATURE_CODE }
      end
    end

    assert_response :redirect
    event = Lakeraven::EHR::AuditEvent.where(entity_type: "DocumentReference").order(:id).last
    assert_equal "0", event.outcome
    assert_equal "E", event.action
    assert_equal Lakeraven::EHR::DemoVisitsController::AUTHOR_DUZ.to_s, event.agent_who_identifier
    assert_equal "progress_note_signed; patient #{DFN}; content-sha256 #{Digest::SHA256.hexdigest(NOTE_TEXT)}",
                 event.outcome_desc
    event.attributes.each_value do |value|
      refute_includes value.to_s, SIGNATURE_CODE
    end
  end

  private

  # Same gate-opening as ConsentWriteTestHelper#with_demo_visits_gate_open:
  # the demo UI 404s outside development, so the gate is opened for the block.
  def with_demo_visits_gate_open
    Lakeraven::EHR::DemoVisitsController.class_eval do
      alias_method :__note_audit_real_require_demo_mode!, :require_demo_mode!
      def require_demo_mode!; end
    end
    yield
  ensure
    Lakeraven::EHR::DemoVisitsController.class_eval do
      alias_method :require_demo_mode!, :__note_audit_real_require_demo_mode!
      remove_method :__note_audit_real_require_demo_mode!
    end
  end
end
