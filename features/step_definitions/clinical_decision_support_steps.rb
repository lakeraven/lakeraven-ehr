# frozen_string_literal: true

Given("a patient with due clinical reminders") do
  @reminders ||= []
  @reminders.concat([
    { name: "Diabetes A1C screening", status: "DUE", priority: "high" },
    { name: "Flu vaccine", status: "DUE", priority: "moderate" },
    { name: "Blood pressure check", status: "DUE", priority: "low" }
  ])
end

Given("a patient with known allergies") do
  @allergies ||= []
  @allergies.concat([
    { allergen: "Penicillin", severity: "severe" },
    { allergen: "Aspirin", severity: "moderate" }
  ])
end

When("I check the patient's background alerts") do
  @service = Lakeraven::EHR::ClinicalAlertService.new(
    reminders: @reminders || [],
    allergies: @allergies || []
  )
  @alerts = @service.background_alerts
end

Then("I should see only DUE reminders") do
  reminder_alerts = @alerts.select { |a| a.type == :reminder }
  assert reminder_alerts.any?, "Expected DUE reminder alerts"
end

Then("each reminder should have a severity level") do
  reminder_alerts = @alerts.select { |a| a.type == :reminder }
  reminder_alerts.each do |a|
    assert %i[high moderate low].include?(a.severity), "Expected severity, got #{a.severity}"
  end
end

Then("I should see allergy alerts with severity badges") do
  allergy_alerts = @alerts.select { |a| a.type == :allergy }
  assert allergy_alerts.any?, "Expected allergy alerts"
  allergy_alerts.each { |a| assert a.severity.present? }
end

Then("allergy severity should be mapped from the severity field") do
  allergy_alerts = @alerts.select { |a| a.type == :allergy }
  severe = allergy_alerts.find { |a| a.description == "Penicillin" }
  assert_equal :high, severe.severity
end

Then("the drug interactions list should be empty") do
  assert_equal [], @service.drug_interactions
end

Then("I should see a severity summary with high, moderate, and low counts") do
  summary = @service.severity_summary
  assert summary[:high].positive?, "Expected high count > 0"
  assert summary[:moderate].positive?, "Expected moderate count > 0"
  assert summary[:low].positive?, "Expected low count > 0"
end
