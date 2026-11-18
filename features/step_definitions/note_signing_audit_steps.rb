# frozen_string_literal: true

require "digest"

# Steps for features/encounter/note_signing_audit.feature (lakeraven-ehr#960).
# The note and signing steps themselves are the existing ones in
# demo_visit_charting_steps.rb; these only read the AuditEvent the signing
# is expected to leave.
#
# The success row holds two hashes. content-sha256 is of the body rows the
# provider signed. record-sha256 is of ALL the body rows read again after the
# sign action, signature block included: the note as filed. A verifier
# re-reads the body and compares the hash of all its rows with record-sha256.

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

# The body rows the fake note gateway currently holds for the note: once
# signed, the written rows, the signature block and anything appended since.
def note_signing_body_rows
  @note_gateway.fetch_body(@note_result.note_ien)
end

# The rows the provider wrote, which are the rows that were signed.
def note_signing_written_rows
  @note_gateway.written_rows(@note_result.note_ien)
end

def note_signing_content_hash
  @audit_event.outcome_desc.to_s[/; content-sha256 ([0-9a-f]{64});/, 1]
end

def note_signing_content_rows
  @audit_event.outcome_desc.to_s[/; content-rows (\d+);/, 1]&.to_i
end

def note_signing_record_hash
  @audit_event.outcome_desc.to_s[/; record-sha256 ([0-9a-f]{64});/, 1]
end

def note_signing_record_rows
  @audit_event.outcome_desc.to_s[/; record-rows (\d+)\z/, 1]&.to_i
end

# What a later verifier does: ALL the body rows, joined with "\n", compared
# with the record hash. Not the first n rows: that check is blind to appends.
def note_signing_verifier_hash(rows)
  refute_nil note_signing_record_hash,
    "the audit event records no record-sha256: #{@audit_event.outcome_desc.inspect}"
  refute_nil rows, "the note body could not be read"
  Digest::SHA256.hexdigest(rows.join("\n"))
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
  rows = note_signing_written_rows
  refute_nil rows
  assert_match(/\Aprogress_note_signed; patient \d+; content-sha256 [0-9a-f]{64}; content-rows \d+(;|\z)/,
               @audit_event.outcome_desc.to_s)
  assert_equal rows.size, @audit_event.outcome_desc.to_s[/; content-rows (\d+)(;|\z)/, 1]&.to_i
  assert_equal Digest::SHA256.hexdigest(rows.join("\n")),
               @audit_event.outcome_desc.to_s[/; content-sha256 ([0-9a-f]{64})(;|\z)/, 1]
end

Then("the note signing audit event should hold the SHA-256 and row count of the note as filed") do
  rows = note_signing_body_rows
  refute_nil rows
  assert_match(/; content-rows \d+; record-sha256 [0-9a-f]{64}; record-rows \d+\z/, @audit_event.outcome_desc.to_s)
  assert_equal rows.size, note_signing_record_rows
  assert_equal Digest::SHA256.hexdigest(rows.join("\n")), note_signing_record_hash
end

# The fake files the signature block on signing, as TIU does, so the record
# is more than the signed text and its hash differs from the content hash.
Then("the note as filed should include the signature block") do
  assert_equal note_signing_written_rows + FakeProgressNoteGateway::SIGNATURE_ROWS, note_signing_body_rows
  assert_operator note_signing_record_rows, :>, note_signing_content_rows
  refute_equal note_signing_content_hash, note_signing_record_hash
end

When("the note text is later changed to {string}") do |text|
  written = @note_gateway.update_text(@note_result.note_ien, text)
  assert written[:success]
end

When("the note text is later changed to:") do |text|
  written = @note_gateway.update_text(@note_result.note_ien, text)
  assert written[:success]
end

When("a row {string} is appended to the signed note") do |row|
  assert @note_gateway.signed?(@note_result.note_ien), "the note was not signed"
  before = note_signing_body_rows
  @note_gateway.append_row(@note_result.note_ien, row)
  assert_equal before + [ row ], note_signing_body_rows
end

# The check this issue replaced: hashing only the first content-rows rows.
# It still passes after an append, which is why it is not the verifier.
Then("the signed rows alone should still reproduce the content hash") do
  count = note_signing_content_rows
  refute_nil count, "the audit event records no content-rows count: #{@audit_event.outcome_desc.inspect}"
  assert_equal note_signing_content_hash,
               Digest::SHA256.hexdigest(note_signing_body_rows.first(count).join("\n"))
end

# Re-hashes ALL the rows the gateway holds NOW, the way a verifier would, so
# this fails if the note was not in fact changed.
Then("the record hash should match the current note body") do
  assert_equal note_signing_record_hash, note_signing_verifier_hash(note_signing_body_rows)
end

Then("the record hash should no longer match the current note body") do
  refute_equal note_signing_record_hash, note_signing_verifier_hash(note_signing_body_rows)
end

# The re-read goes through the production gateway's parsing: the fake API
# returns a TIU display built from a header and the signed note's body rows,
# which already end with the signature block the fake filed on signing. The
# text is built the way RpmsRpc::ProgressNote.fetch_text returns it: rows
# joined with a separator and NO trailing separator (the transport has
# already removed the reply's terminator), so a trailing separator here
# would be a blank row the note does not have.
When("TIU later returns the signed note with a {string} header and a signature block") do |status|
  assert @note_gateway.signed?(@note_result.note_ien), "the note was not signed"
  text = (note_signing_tiu_header(status) + [ "" ] + note_signing_body_rows).join("\r")
  @reread_text = text
  @reread_body = Lakeraven::EHR::ProgressNoteGateway.fetch_body(
    @note_result.note_ien, via: FakeTiuRecordTextApi.new(text)
  )
end

Then("the re-read note should differ from the body alone") do
  assert_includes @reread_text, "STATUS: COMPLETED"
  assert_includes @reread_text, "/es/ PROVIDER,SYNTHETIC"
  refute_nil @reread_body
  assert_operator @reread_body.size, :>, note_signing_written_rows.size,
    "the signature block should follow the body rows"
end

Then("the record hash should match the re-read note body") do
  assert_equal note_signing_record_hash, note_signing_verifier_hash(@reread_body)
end

Then("the record hash should no longer match the re-read note body") do
  refute_equal note_signing_record_hash, note_signing_verifier_hash(@reread_body)
end

# The body changes when the sign action runs, before the signature rows are
# appended: after the signer's read, before filing.
Given("the note text will be changed to {string} between the signer's read and filing") do |text|
  @signed_rows = note_signing_written_rows
  refute_nil @signed_rows
  refute_equal @signed_rows, text.split("\n", -1)
  @note_gateway.before_filing do |note_ien|
    written = @note_gateway.update_text(note_ien, text)
    assert written[:success]
  end
end

# The filed note does not start with the rows that were signed, so the event
# records the signature and a marker that never verifies.
Then("the note signing audit event should record that the filed note does not match what was signed") do
  desc = @audit_event.outcome_desc.to_s
  refute_equal @signed_rows, note_signing_body_rows.first(@signed_rows.size),
    "the scenario did not change the note before filing"
  assert_equal "progress_note_signed; patient #{@dfn}; " \
               "content-sha256 #{Digest::SHA256.hexdigest(@signed_rows.join("\n"))}; " \
               "content-rows #{@signed_rows.size}; record-sha256 mismatch", desc
  refute_match(/record-sha256 [0-9a-f]{64}/, desc)
  refute_match(/record-rows/, desc)
end
