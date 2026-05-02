# frozen_string_literal: true

# Clinical alert service step definitions

Given("clinical reminders:") do |table|
  @reminders = table.hashes.map do |row|
    { name: row["name"], status: row["status"], priority: row["priority"].presence }
  end
  @allergies ||= []
end

Given("patient allergies:") do |table|
  @allergies = table.hashes.map do |row|
    {
      allergen: row["allergen"],
      severity: row["severity"].presence,
      criticality: row["criticality"].presence
    }
  end
  @reminders ||= []
end

When("I aggregate background alerts") do
  service = Lakeraven::EHR::ClinicalAlertService.new(
    reminders: @reminders || [],
    allergies: @allergies || []
  )
  @alerts = service.background_alerts
  @severity_summary = service.severity_summary
end

When("I check drug interactions") do
  service = Lakeraven::EHR::ClinicalAlertService.new(
    reminders: @reminders || [],
    allergies: @allergies || []
  )
  @drug_interactions = service.drug_interactions
end

Then("there should be {int} alert(s)") do |count|
  assert_equal count, @alerts.length, "Expected #{count} alerts, got #{@alerts.length}"
end

Then("the first alert type should be {string}") do |expected|
  assert_equal expected.to_sym, @alerts.first.type
end

Then("the first alert severity should be {string}") do |expected|
  assert_equal expected.to_sym, @alerts.first.severity
end

Then("the drug interactions should be empty") do
  assert @drug_interactions.empty?, "Expected empty drug interactions"
end

Then("the severity summary should show {int} high alert(s)") do |count|
  assert_equal count, @severity_summary[:high]
end

Then("the severity summary should show {int} moderate alert(s)") do |count|
  assert_equal count, @severity_summary[:moderate]
end

Then("the severity summary should show {int} low alert(s)") do |count|
  assert_equal count, @severity_summary[:low]
end
