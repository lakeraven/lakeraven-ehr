# frozen_string_literal: true

require "digest"

# Steps for features/encounter/note_signing_audit.feature (lakeraven-ehr#960).
# The note and signing steps themselves are the existing ones in
# demo_visit_charting_steps.rb; these only read the AuditEvent the signing
# is expected to leave.

Before("@note_signing_audit") do
  Lakeraven::EHR::AuditEvent.delete_all
end

def note_signing_text
  @note_gateway.text_updates.last&.fetch(:text)
end

def note_signing_recorded_hash
  @audit_event.outcome_desc.to_s[/content-sha256 ([0-9a-f]{64})/, 1]
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
  text = note_signing_text
  refute_nil text
  @audit_event.attributes.each do |column, value|
    next if value.nil?

    refute_includes value.to_s, text.strip, "AuditEvent##{column} must not contain the note text"
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

Then("the note signing audit event should hold the SHA-256 of the signed note text") do
  text = note_signing_text
  refute_nil text
  assert_match(/\Aprogress_note_signed; /, @audit_event.outcome_desc.to_s)
  assert_equal Digest::SHA256.hexdigest(text), note_signing_recorded_hash
end

When("the note text is later changed to {string}") do |text|
  written = @note_gateway.update_text(@note_result.note_ien, text)
  assert written[:success]
end

Then("the recorded hash should no longer match the note text") do
  current = @note_gateway.fetch_text(@note_result.note_ien)
  refute_nil current
  refute_nil note_signing_recorded_hash
  refute_equal Digest::SHA256.hexdigest(current), note_signing_recorded_hash
end
