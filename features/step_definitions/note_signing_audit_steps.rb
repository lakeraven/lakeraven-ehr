# frozen_string_literal: true

require "digest"

# Steps for features/encounter/note_signing_audit.feature (lakeraven-ehr#960).
# The note and signing steps themselves are the existing ones in
# demo_visit_charting_steps.rb; these only read the AuditEvent the signing
# is expected to leave.

Before("@note_signing_audit") do
  Lakeraven::EHR::AuditEvent.delete_all
end

After("@note_signing_audit") do
  Lakeraven::EHR::AuditEvent.delete_all
end

# A TIU API whose GET RECORD TEXT display is whatever the scenario built.
class FakeTiuRecordTextApi
  def initialize(text)
    @text = text
  end

  def fetch_text(_note_ien) = @text
end

# Synthetic header, laid out like TIU GET RECORD TEXT's.
def note_signing_tiu_header(status)
  [
    " LOCAL TITLE: Synthetic Clinic Note",
    "STANDARD TITLE: SYNTHETIC OUTPATIENT NOTE",
    "      AUTHOR: PROVIDER,SYNTHETIC   EXP COSIGNER:",
    "     URGENCY:                            STATUS: #{status}"
  ]
end

NOTE_SIGNING_SIGNATURE_BLOCK = [ "", "/es/ PROVIDER,SYNTHETIC", "Signed: 11/15/2026 10:00" ].freeze

# The body rows the fake note gateway currently holds for the note.
def note_signing_body_rows
  @note_gateway.fetch_body(@note_result.note_ien)
end

def note_signing_recorded_hash
  @audit_event.outcome_desc.to_s[/content-sha256 ([0-9a-f]{64})/, 1]
end

def note_signing_recorded_rows
  @audit_event.outcome_desc.to_s[/content-rows (\d+)\z/, 1]&.to_i
end

# What a later verifier does: the first n body rows, joined with "\n".
def note_signing_verifier_hash(rows)
  count = note_signing_recorded_rows
  refute_nil count, "the audit event records no content-rows count: #{@audit_event.outcome_desc.inspect}"
  refute_nil rows, "the note body could not be read"
  Digest::SHA256.hexdigest(rows.first(count).join("\n"))
end

Then("exactly one note signing audit event should be recorded") do
  events = Lakeraven::EHR::AuditEvent.where(entity_type: "DocumentReference").to_a
  assert_equal 1, events.size,
    "expected exactly one DocumentReference AuditEvent for the signing, found #{events.size}"
  @audit_event = events.first
end

Then("the note signing audit event should identify the signed note") do
  assert_equal @note_result.note_ien.to_s, @audit_event.entity_identifier
  assert_equal @note_result.note_ien.to_s, @audit_event.entity_id.to_s
end

Then("the note signing audit event should identify no note") do
  assert_nil @audit_event.entity_identifier
  assert_nil @audit_event.entity_id
end

Then("the note signing audit event should name patient {int}") do |dfn|
  assert_match(/(\A|; )patient #{dfn}(;|\z)/, @audit_event.outcome_desc.to_s)
end

Then("the note signing audit event should give the reason {string}") do |reason|
  assert_match(/\Aprogress_note_sign_refused; .*reason #{Regexp.escape(reason)}\z/,
               @audit_event.outcome_desc.to_s)
  refute_match(/sha256/i, @audit_event.outcome_desc.to_s)
end

Then("the note signing audit event should not contain {string}") do |secret|
  @audit_event.attributes.each do |column, value|
    next if value.nil?

    refute_includes value.to_s, secret, "AuditEvent##{column} must not contain #{secret.inspect}"
  end
end

Then("the note signing audit event should not contain the note text") do
  rows = note_signing_body_rows.reject { |row| row.strip.empty? }
  refute_empty rows
  @audit_event.attributes.each do |column, value|
    next if value.nil?

    rows.each do |row|
      refute_includes value.to_s, row.strip, "AuditEvent##{column} must not contain the note text"
    end
  end
end

Then("the note signing audit event cannot be updated") do
  assert_raises(ActiveRecord::ReadOnlyRecord) { @audit_event.update!(outcome: "8") }
  assert_equal "0", Lakeraven::EHR::AuditEvent.find(@audit_event.id).outcome
end

Then("the note signing audit event cannot be deleted") do
  assert_raises(ActiveRecord::ReadOnlyRecord) { @audit_event.destroy }
  assert Lakeraven::EHR::AuditEvent.exists?(@audit_event.id)
end

Then("the note signing audit event should hold the SHA-256 and row count of the signed note body") do
  rows = note_signing_body_rows
  refute_nil rows
  assert_match(/\Aprogress_note_signed; /, @audit_event.outcome_desc.to_s)
  assert_match(/; content-sha256 [0-9a-f]{64}; content-rows \d+\z/, @audit_event.outcome_desc.to_s)
  assert_equal rows.size, note_signing_recorded_rows
  assert_equal Digest::SHA256.hexdigest(rows.join("\n")), note_signing_recorded_hash
end

When("the note text is later changed to {string}") do |text|
  written = @note_gateway.update_text(@note_result.note_ien, text)
  assert written[:success]
end

When("the note text is later changed to:") do |text|
  written = @note_gateway.update_text(@note_result.note_ien, text)
  assert written[:success]
end

# Re-hashes the body the gateway holds NOW, the way a verifier would, so
# this fails if the text was not in fact changed.
Then("the recorded hash should match the current note body") do
  assert_equal note_signing_recorded_hash, note_signing_verifier_hash(note_signing_body_rows)
end

Then("the recorded hash should no longer match the current note body") do
  refute_nil note_signing_recorded_hash
  refute_equal note_signing_recorded_hash, note_signing_verifier_hash(note_signing_body_rows)
end

# The re-read goes through the production gateway's parsing: the fake API
# returns a TIU display built from a header, a body and a signature block.
When("TIU later returns the signed note with a {string} header and a signature block") do |status|
  text = (note_signing_tiu_header(status) + [ "" ] + note_signing_body_rows +
          NOTE_SIGNING_SIGNATURE_BLOCK).join("\r") + "\r"
  @reread_text = text
  @reread_body = Lakeraven::EHR::ProgressNoteGateway.fetch_body(
    @note_result.note_ien, via: FakeTiuRecordTextApi.new(text)
  )
end

Then("the re-read note should differ from the body alone") do
  assert_includes @reread_text, "STATUS: COMPLETED"
  assert_includes @reread_text, "/es/ PROVIDER,SYNTHETIC"
  refute_nil @reread_body
  assert_operator @reread_body.size, :>, note_signing_recorded_rows,
    "the signature block should follow the body rows"
end

Then("the recorded hash should match the re-read note body") do
  assert_equal note_signing_recorded_hash, note_signing_verifier_hash(@reread_body)
end

Then("the recorded hash should no longer match the re-read note body") do
  refute_nil note_signing_recorded_hash
  refute_equal note_signing_recorded_hash, note_signing_verifier_hash(@reread_body)
end
