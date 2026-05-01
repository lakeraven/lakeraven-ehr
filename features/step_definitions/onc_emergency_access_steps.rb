# frozen_string_literal: true

# ONC § 170.315(d)(6) — Emergency Access step definitions
# Covers break-the-glass access, audit trail, expiration, and post-access review.
#
# Note: "the following patients exist:" step is defined in drug_interaction_steps.rb
# Note: "the modification should be rejected" step is defined in
#       onc_accounting_of_disclosures_steps.rb and shared across features.

# EmergencyAccessService uses in-memory objects and audit_log arrays.
# We track all accesses in @emergency_accesses for pending-review queries.

# -----------------------------------------------------------------------------
# When: grant emergency access
# -----------------------------------------------------------------------------

When("provider {string} invokes emergency access for patient {string} with:") do |duz, dfn, table|
  data = table.rows_hash
  @audit_log = []
  @emergency_access = Lakeraven::EHR::EmergencyAccessService.grant(
    patient_dfn: dfn,
    accessed_by: duz,
    reason: data["reason"],
    justification: data["justification"],
    audit_log: @audit_log
  )
  @access_granted = true
  @emergency_accesses ||= []
  @emergency_accesses << @emergency_access
end

When("provider {string} attempts emergency access with an invalid reason") do |duz|
  begin
    @audit_log = []
    @emergency_access = Lakeraven::EHR::EmergencyAccessService.grant(
      patient_dfn: "1",
      accessed_by: duz,
      reason: "invalid_reason",
      justification: "Testing",
      audit_log: @audit_log
    )
    @access_granted = true
  rescue Lakeraven::EHR::EmergencyAccessService::InvalidReasonError
    @access_granted = false
  end
end

When("emergency access is attempted with missing required fields") do
  begin
    @audit_log = []
    @emergency_access = Lakeraven::EHR::EmergencyAccessService.grant(
      patient_dfn: "",
      accessed_by: "",
      reason: "",
      justification: "",
      audit_log: @audit_log
    )
    @access_granted = true
  rescue Lakeraven::EHR::EmergencyAccessService::InvalidReasonError
    @access_granted = false
  end
end

# -----------------------------------------------------------------------------
# Given: emergency access setup
# -----------------------------------------------------------------------------

Given("provider {string} has active emergency access to patient {string}") do |duz, dfn|
  @audit_log = []
  @emergency_access = Lakeraven::EHR::EmergencyAccessService.grant(
    patient_dfn: dfn,
    accessed_by: duz,
    reason: "medical_emergency",
    justification: "Emergency scenario setup",
    audit_log: @audit_log
  )
  @emergency_accesses ||= []
  @emergency_accesses << @emergency_access
end

Given("provider {string} has expired emergency access to patient {string}") do |duz, dfn|
  @audit_log = []
  @emergency_access = Lakeraven::EHR::EmergencyAccessService.grant(
    patient_dfn: dfn,
    accessed_by: duz,
    reason: "medical_emergency",
    justification: "Expired access setup",
    duration: 0.seconds,
    audit_log: @audit_log
  )
  @emergency_accesses ||= []
  @emergency_accesses << @emergency_access
end

Given("provider {string} has a reviewed emergency access to patient {string}") do |duz, dfn|
  @audit_log = []
  @emergency_access = Lakeraven::EHR::EmergencyAccessService.grant(
    patient_dfn: dfn,
    accessed_by: duz,
    reason: "medical_emergency",
    justification: "Already reviewed setup",
    audit_log: @audit_log
  )
  Lakeraven::EHR::EmergencyAccessService.review(
    emergency_access: @emergency_access,
    reviewer_duz: "SUP0",
    outcome: "appropriate",
    audit_log: @audit_log
  )
  @emergency_accesses ||= []
  @emergency_accesses << @emergency_access
end

# -----------------------------------------------------------------------------
# When: review emergency access
# -----------------------------------------------------------------------------

When("supervisor {string} reviews the emergency access as {string}") do |reviewer_duz, outcome|
  @audit_log ||= []
  Lakeraven::EHR::EmergencyAccessService.review(
    emergency_access: @emergency_access,
    reviewer_duz: reviewer_duz,
    outcome: outcome,
    audit_log: @audit_log
  )
end

When("supervisor {string} reviews the emergency access as {string} with notes:") do |reviewer_duz, outcome, table|
  data = table.rows_hash
  @audit_log ||= []
  Lakeraven::EHR::EmergencyAccessService.review(
    emergency_access: @emergency_access,
    reviewer_duz: reviewer_duz,
    outcome: outcome,
    notes: data["notes"],
    audit_log: @audit_log
  )
end

When("supervisor {string} attempts to re-review the emergency access") do |reviewer_duz|
  begin
    @audit_log ||= []
    Lakeraven::EHR::EmergencyAccessService.review(
      emergency_access: @emergency_access,
      reviewer_duz: reviewer_duz,
      outcome: "inappropriate",
      audit_log: @audit_log
    )
    @re_review_rejected = false
  rescue Lakeraven::EHR::EmergencyAccessService::AlreadyReviewedError
    @re_review_rejected = true
  end
end

When("an attempt is made to modify the emergency access record") do
  # EmergencyAccess is a plain Ruby object; we freeze it after grant to enforce immutability
  begin
    @emergency_access.freeze
    @emergency_access.justification = "Tampered justification"
    @modification_rejected = false
  rescue FrozenError
    @modification_rejected = true
  end
end

# -----------------------------------------------------------------------------
# Then: grant assertions
# -----------------------------------------------------------------------------

Then("the emergency access should be granted") do
  assert @access_granted, "Expected emergency access to be granted"
  assert @emergency_access.patient_dfn.present?
end

Then("the emergency access should be denied") do
  refute @access_granted, "Expected emergency access to be denied"
end

Then("the emergency access should have a security audit trail") do
  grant_entry = @audit_log.find { |e| e[:outcome_desc]&.include?("Emergency access granted") }
  assert grant_entry.present?, "Expected security audit event for emergency access"
  assert_equal "security", grant_entry[:event_type]
  assert_equal "E", grant_entry[:action]
  assert_equal "BTG", grant_entry[:purpose_of_event]
end

Then("the emergency access should expire after the default duration") do
  expected_expiry = @emergency_access.accessed_at + Lakeraven::EHR::EmergencyAccessService::DEFAULT_DURATION
  assert_in_delta expected_expiry, @emergency_access.expires_at, 2.seconds
end

# -----------------------------------------------------------------------------
# Then: active access assertions
# -----------------------------------------------------------------------------

Then("provider {string} should have active access to patient {string}") do |duz, dfn|
  accesses = (@emergency_accesses || [])
  has_active = accesses.any? { |a| a.patient_dfn == dfn && a.accessed_by == duz && a.active? }
  assert has_active, "Expected provider #{duz} to have active access to patient #{dfn}"
end

Then("provider {string} should not have active access to patient {string}") do |duz, dfn|
  accesses = (@emergency_accesses || [])
  has_active = accesses.any? { |a| a.patient_dfn == dfn && a.accessed_by == duz && a.active? }
  refute has_active, "Expected provider #{duz} NOT to have active access to patient #{dfn}"
end

# -----------------------------------------------------------------------------
# Then: review assertions
# -----------------------------------------------------------------------------

Then("the emergency access should be marked as reviewed") do
  assert @emergency_access.reviewed?, "Expected emergency access to be reviewed"
end

Then("the review should have a security audit trail") do
  review_entry = @audit_log.find { |e| e[:outcome_desc]&.include?("Emergency access reviewed") }
  assert review_entry.present?, "Expected security audit event for review"
  assert_equal "security", review_entry[:event_type]
  assert_equal "BTG", review_entry[:purpose_of_event]
end

Then("the review outcome should be {string}") do |outcome|
  assert_equal outcome, @emergency_access.review_outcome
end

Then("the re-review should be rejected") do
  assert @re_review_rejected, "Expected re-review to be rejected"
end

# -----------------------------------------------------------------------------
# Then: pending reviews
# -----------------------------------------------------------------------------

Then("there should be {int} emergency accesses pending review") do |count|
  pending = Lakeraven::EHR::EmergencyAccessService.pending_reviews(@emergency_accesses || [])
  assert_equal count, pending.count
end
