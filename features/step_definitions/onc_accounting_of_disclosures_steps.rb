# frozen_string_literal: true

# ONC § 170.315(d)(11) — Accounting of Disclosures step definitions
# Covers disclosure recording, patient-facing reports, immutability, and audit trail.
#
# Note: "the following patients exist:" step is defined in drug_interaction_steps.rb

# -----------------------------------------------------------------------------
# When: record disclosures
# -----------------------------------------------------------------------------

When("a disclosure is recorded for patient {string} with:") do |dfn, table|
  data = table.rows_hash
  @disclosure = Lakeraven::EHR::DisclosureService.record(
    patient_dfn: dfn,
    recipient_name: data["recipient_name"],
    recipient_type: data["recipient_type"],
    purpose: data["purpose"],
    data_disclosed: data["data_disclosed"],
    disclosed_by: data["disclosed_by"]
  )
  @disclosure_valid = true
end

When("a disclosure is recorded with missing required fields") do
  begin
    @disclosure = Lakeraven::EHR::DisclosureService.record(
      patient_dfn: "",
      recipient_name: "",
      purpose: "",
      data_disclosed: "",
      disclosed_by: ""
    )
    @disclosure_valid = true
  rescue ActiveRecord::RecordInvalid
    @disclosure_valid = false
  end
end

When("a disclosure is recorded with timing for patient {string}") do |dfn|
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  @disclosure = Lakeraven::EHR::DisclosureService.record(
    patient_dfn: dfn,
    recipient_name: "Test Recipient",
    purpose: "treatment",
    data_disclosed: "Demographics",
    disclosed_by: "789"
  )
  @disclosure_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
end

# -----------------------------------------------------------------------------
# Given: disclosure history setup
# -----------------------------------------------------------------------------

Given("patient {string} has the following recent disclosure history:") do |dfn, table|
  @export_patient_dfn = dfn
  table.hashes.each do |row|
    Lakeraven::EHR::DisclosureService.record(
      patient_dfn: dfn,
      recipient_name: row["recipient_name"],
      purpose: row["purpose"],
      data_disclosed: "Clinical records",
      disclosed_by: "789",
      disclosed_at: row["months_ago"].to_i.months.ago
    )
  end
end

Given("patient {string} has a disclosure from {int} years ago") do |dfn, years|
  Lakeraven::EHR::DisclosureService.record(
    patient_dfn: dfn,
    recipient_name: "Historical Recipient",
    purpose: "treatment",
    data_disclosed: "Clinical records",
    disclosed_by: "789",
    disclosed_at: years.years.ago
  )
end

Given("patient {string} has a recorded disclosure") do |dfn|
  @disclosure = Lakeraven::EHR::DisclosureService.record(
    patient_dfn: dfn,
    recipient_name: "Test Recipient",
    purpose: "treatment",
    data_disclosed: "Demographics",
    disclosed_by: "789"
  )
end

# -----------------------------------------------------------------------------
# When: patient queries and export
# -----------------------------------------------------------------------------

When("patient {string} requests their accounting of disclosures") do |dfn|
  @disclosure_report = Lakeraven::EHR::DisclosureService.accounting(dfn).to_a
end

When("the disclosure report is exported for patient {string}") do |dfn|
  @export_patient_dfn = dfn
  @disclosure_export = Lakeraven::EHR::DisclosureService.export_report(dfn)
end

When("an attempt is made to modify the disclosure") do
  begin
    @disclosure.update!(recipient_name: "Modified Recipient")
    @modification_rejected = false
  rescue ActiveRecord::ReadOnlyRecord
    @modification_rejected = true
  end
end

When("an attempt is made to delete the disclosure") do
  begin
    @disclosure.destroy!
    @deletion_rejected = false
  rescue ActiveRecord::ReadOnlyRecord
    @deletion_rejected = true
  end
end

# -----------------------------------------------------------------------------
# Then: recording assertions
# -----------------------------------------------------------------------------

Then("the disclosure should be recorded successfully") do
  assert @disclosure_valid, "Expected disclosure to be recorded"
  assert @disclosure.persisted?
end

Then("the disclosure should be immutable") do
  assert_raises(ActiveRecord::ReadOnlyRecord) do
    @disclosure.update!(recipient_name: "Changed")
  end
end

Then("the disclosure should have an audit trail entry") do
  audit = Lakeraven::EHR::AuditEvent.where(entity_type: "Disclosure").last
  assert audit.present?, "Expected audit event for disclosure"
  assert_match(/PHI disclosed/, audit.outcome_desc)
end

Then("the disclosure should fail validation") do
  refute @disclosure_valid, "Expected disclosure to fail validation"
end

# -----------------------------------------------------------------------------
# Then: report assertions
# -----------------------------------------------------------------------------

Then(/^the report should contain (\d+) disclosures?$/) do |count|
  assert_equal count.to_i, @disclosure_report.count,
    "Expected #{count} disclosures, got #{@disclosure_report.count}"
end

Then("each disclosure should include the date, recipient, and purpose") do
  @disclosure_report.each do |d|
    assert d.disclosed_at.present?, "Expected disclosure date"
    assert d.recipient_name.present?, "Expected recipient name"
    assert d.purpose.present?, "Expected purpose"
  end
end

Then("the disclosures should be in reverse chronological order") do
  dates = @disclosure_report.map(&:disclosed_at)
  assert_equal dates, dates.sort.reverse, "Expected reverse chronological order"
end

Then("the {int}-year-old disclosure should be excluded") do |years|
  cutoff = years.years.ago
  old_disclosures = @disclosure_report.select { |d| d.disclosed_at < cutoff }
  assert old_disclosures.empty?, "Expected #{years}-year-old disclosure to be excluded"
end

# -----------------------------------------------------------------------------
# Then: export assertions
# -----------------------------------------------------------------------------

Then("the export should include patient identifier") do
  assert_equal @export_patient_dfn, @disclosure_export[:patient_dfn]
end

Then("the export should include disclosure details") do
  assert @disclosure_export[:disclosures].any?, "Expected disclosure entries"
  entry = @disclosure_export[:disclosures].first
  assert entry[:recipient][:name].present?
  assert entry[:purpose].present?
  assert entry[:date].present?
end

Then("the export should include the reporting period") do
  assert @disclosure_export[:period_start].present?
  assert @disclosure_export[:period_end].present?
end

# -----------------------------------------------------------------------------
# Then: immutability assertions
# -----------------------------------------------------------------------------

Then("the modification should be rejected") do
  assert @modification_rejected, "Expected modification to be rejected"
end

Then("the deletion should be rejected") do
  assert @deletion_rejected, "Expected deletion to be rejected"
end

# -----------------------------------------------------------------------------
# Then: performance
# -----------------------------------------------------------------------------

Then("the disclosure recording should complete within {int} seconds") do |seconds|
  assert @disclosure_elapsed < seconds.to_f,
    "Disclosure recording took #{@disclosure_elapsed}s, expected < #{seconds}s"
end
