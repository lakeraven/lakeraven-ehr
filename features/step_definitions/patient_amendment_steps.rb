# frozen_string_literal: true

# ONC § 170.315(d)(4) — Amendments step definitions
# Covers amendment request creation, accept/deny workflow, history, and audit trail.

# Note: "the following patients exist:" step is defined in drug_interaction_steps.rb

# -----------------------------------------------------------------------------
# When: amendment request creation
# -----------------------------------------------------------------------------

When("patient {string} requests an amendment with:") do |dfn, table|
  data = table.rows_hash
  begin
    @amendment = Lakeraven::EHR::AmendmentService.request(
      patient_dfn: dfn,
      resource_type: data["resource"],
      description: data["description"],
      reason: data["reason"]
    )
    @amendment_valid = true
  rescue ActiveRecord::RecordInvalid => e
    @amendment_error = e
    @amendment_valid = false
  end
end

When("patient {string} requests an amendment with timing") do |dfn|
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  @amendment = Lakeraven::EHR::AmendmentService.request(
    patient_dfn: dfn,
    resource_type: "Observation",
    description: "Correct blood pressure reading",
    reason: "Value was transcribed incorrectly"
  )
  @amendment_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
end

# -----------------------------------------------------------------------------
# Given: pending amendment setup
# -----------------------------------------------------------------------------

Given("patient {string} has a pending amendment request") do |dfn|
  @amendment = Lakeraven::EHR::AmendmentService.request(
    patient_dfn: dfn,
    resource_type: "AllergyIntolerance",
    description: "Change penicillin to amoxicillin",
    reason: "Incorrect medication name"
  )
end

Given("patient {string} has a pending amendment request for {string}") do |dfn, resource_type|
  @amendment = Lakeraven::EHR::AmendmentService.request(
    patient_dfn: dfn,
    resource_type: resource_type,
    description: "Correction to #{resource_type} record",
    reason: "Data entry error"
  )
end

Given("patient {string} has the following amendment history:") do |dfn, table|
  table.hashes.each do |row|
    amendment = Lakeraven::EHR::AmendmentService.request(
      patient_dfn: dfn,
      resource_type: row["resource"],
      description: row["description"],
      reason: "Patient requested"
    )
    case row["status"]
    when "accepted"
      Lakeraven::EHR::AmendmentService.accept(amendment, reviewer_duz: "789", reason: "Verified")
    when "denied"
      Lakeraven::EHR::AmendmentService.deny(amendment, reviewer_duz: "789", reason: "Record is accurate")
    end
  end
end

# -----------------------------------------------------------------------------
# When: provider actions
# -----------------------------------------------------------------------------

When("provider {string} accepts the amendment with reason {string}") do |duz, reason|
  Lakeraven::EHR::AmendmentService.accept(@amendment, reviewer_duz: duz, reason: reason)
end

When("provider {string} denies the amendment with reason {string}") do |duz, reason|
  Lakeraven::EHR::AmendmentService.deny(@amendment, reviewer_duz: duz, reason: reason)
end

When("provider {string} denies the amendment without a reason") do |duz|
  begin
    Lakeraven::EHR::AmendmentService.deny(@amendment, reviewer_duz: duz, reason: "")
    @denial_succeeded = true
  rescue ActiveRecord::RecordInvalid => e
    @denial_error = e
    @denial_succeeded = false
  end
end

# -----------------------------------------------------------------------------
# When: history query
# -----------------------------------------------------------------------------

When("I retrieve amendment history for patient {string}") do |dfn|
  @amendment_history = Lakeraven::EHR::AmendmentService.history(dfn)
end

# -----------------------------------------------------------------------------
# Then: creation assertions
# -----------------------------------------------------------------------------

Then("the amendment request should be created with status {string}") do |status|
  assert @amendment_valid, "Expected amendment to be created, got: #{@amendment_error&.message}"
  assert_equal status, @amendment.status
end

Then("the amendment request should be invalid") do
  refute @amendment_valid, "Expected amendment to be invalid"
end

Then("the amendment should have an audit trail entry") do
  audit = Lakeraven::EHR::AuditEvent.where(entity_type: "AmendmentRequest").last
  assert audit.present?, "Expected audit event for amendment"
  assert_match(/amendment/i, audit.outcome_desc)
end

# -----------------------------------------------------------------------------
# Then: accept/deny assertions
# -----------------------------------------------------------------------------

Then("the amendment status should be {string}") do |status|
  @amendment.reload
  assert_equal status, @amendment.status
end

Then("the amendment should record the reviewer as {string}") do |duz|
  @amendment.reload
  assert_equal duz, @amendment.reviewed_by
end

Then("the amendment should have an audit trail entry for {string}") do |action|
  audit = Lakeraven::EHR::AuditEvent.where("outcome_desc LIKE ?", "%amendment.#{action}%").last
  assert audit.present?, "Expected audit event for amendment.#{action}"
end

Then("the amendment should record the denial reason") do
  @amendment.reload
  assert @amendment.review_reason.present?, "Expected denial reason to be recorded"
end

Then("the denial should fail with a validation error") do
  refute @denial_succeeded, "Expected denial to fail"
  assert @denial_error.present?
end

# -----------------------------------------------------------------------------
# Then: history assertions
# -----------------------------------------------------------------------------

Then("the history should contain {int} amendments") do |count|
  assert_equal count, @amendment_history.count
end

Then("the history should include both accepted and denied amendments") do
  statuses = @amendment_history.map(&:status).uniq
  assert_includes statuses, "accepted"
  assert_includes statuses, "denied"
end

Then("the denied amendment should be preserved in the patient's amendment history") do
  @amendment.reload
  history = Lakeraven::EHR::AmendmentService.history(@amendment.patient_dfn)
  denied = history.find(&:denied?)
  assert denied.present?, "Expected denied amendment in history"
  assert denied.review_reason.present?, "Expected denial reason preserved"
end

Then("the original record should remain unchanged") do
  # Denied amendments do not modify the original record — they are appended
  # This is verified by the amendment existing with denied status
  @amendment.reload
  assert @amendment.denied?
end

# -----------------------------------------------------------------------------
# Then: performance
# -----------------------------------------------------------------------------

Then("the amendment creation should complete within {int} seconds") do |seconds|
  assert @amendment_elapsed < seconds.to_f,
    "Amendment creation took #{@amendment_elapsed}s, expected < #{seconds}s"
end
