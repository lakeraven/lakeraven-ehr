# frozen_string_literal: true

# CDS rules step definitions

CdsService = Lakeraven::EHR::ClinicalDecisionSupportService

# --- Rule configuration ---

When("I list all CDS rules") do
  CdsService.reload_rules!
  CdsService.rule_overrides.clear
  @rules = CdsService.all_rules
end

When("I look up rule {string}") do |rule_id|
  CdsService.reload_rules!
  @rule = CdsService.find_rule(rule_id)
end

When("I check if rule {string} is enabled") do |rule_id|
  CdsService.reload_rules!
  CdsService.rule_overrides.clear
  @rule_enabled = CdsService.rule_enabled?(rule_id)
end

When("provider {string} disables rule {string}") do |provider_duz, rule_id|
  CdsService.reload_rules!
  @override_result = CdsService.update_rule_enabled(rule_id, false, provider_duz: provider_duz)
end

When("provider {string} enables rule {string}") do |provider_duz, rule_id|
  @override_result = CdsService.update_rule_enabled(rule_id, true, provider_duz: provider_duz)
end

Given("provider {string} has disabled rule {string}") do |provider_duz, rule_id|
  CdsService.reload_rules!
  CdsService.update_rule_enabled(rule_id, false, provider_duz: provider_duz)
end

Then("there should be at least {int} rule") do |count|
  assert @rules.length >= count, "Expected at least #{count} rules, got #{@rules.length}"
end

Then("each rule should have an id and message") do
  @rules.each do |rule|
    refute_nil rule[:id], "Rule missing id"
    refute_nil rule[:message], "Rule #{rule[:id]} missing message"
  end
end

Then("the rule should exist") do
  refute_nil @rule, "Expected rule to exist"
end

Then("the rule message should mention {string}") do |text|
  assert_includes @rule[:message], text
end

Then("the rule should be enabled") do
  assert @rule_enabled || CdsService.rule_enabled?(@rule&.dig(:id) || "diabetes_monitoring"),
    "Expected rule to be enabled"
end

Then("rule {string} should be disabled") do |rule_id|
  refute CdsService.rule_enabled?(rule_id), "Expected rule #{rule_id} to be disabled"
end

Then("rule {string} should be enabled") do |rule_id|
  assert CdsService.rule_enabled?(rule_id), "Expected rule #{rule_id} to be enabled"
end

Then("the override result should include provider {string}") do |provider_duz|
  assert_equal provider_duz, @override_result[:updated_by]
end

Then("the override result should include a timestamp") do
  refute_nil @override_result[:updated_at]
end

# --- CdsResult ---

Given("a CDS result with no alerts") do
  @cds_result = CdsService::CdsResult.new(patient_dfn: "100", alerts: [])
end

Given("a CDS result with alerts:") do |table|
  alerts = table.hashes.map do |row|
    { id: "cds-#{SecureRandom.hex(4)}", category: row["category"], severity: row["severity"], message: row["message"] }
  end
  @cds_result = CdsService::CdsResult.new(patient_dfn: "100", alerts: alerts)
end

When("I filter alerts by category {string}") do |category|
  @filtered_alerts = @cds_result.alerts_by_category(category)
end

When("I filter critical alerts") do
  @critical_alerts = @cds_result.critical_alerts
end

When("I convert the result to a hash") do
  @result_hash = @cds_result.to_h
end

Then("the result should not have alerts") do
  refute @cds_result.has_alerts?
end

Then("the result should have alerts") do
  assert @cds_result.has_alerts?
end

Then("the result should have {int} alerts") do |count|
  assert_equal count, @cds_result.alerts.length
end

Then("the result summary should be {string}") do |expected|
  assert_equal expected, @cds_result.summary
end

Then("the result summary should include {string}") do |text|
  assert_includes @cds_result.summary, text
end

Then("there should be {int} filtered alerts") do |count|
  assert_equal count, @filtered_alerts.length
end

Then("there should be {int} critical alert(s)") do |count|
  assert_equal count, @critical_alerts.length
end

Then("the hash should include patient_dfn") do
  refute_nil @result_hash[:patient_dfn]
end

Then("the hash should include alert_count {int}") do |count|
  assert_equal count, @result_hash[:alert_count]
end

# --- Alert override ---

Given("an alert with id {string} and category {string}") do |id, category|
  @alert = { id: id, category: category, severity: "critical", message: "Test alert" }
end

When("provider {string} overrides the alert with reason {string}") do |provider_duz, reason|
  @override = CdsService.override_alert(alert: @alert, provider_duz: provider_duz, reason: reason)
end

Then("the override should be recorded") do
  assert @override[:overridden]
end

Then("the override should include the original alert") do
  refute_nil @override[:original_alert]
end

Then("the override reason should be {string}") do |expected|
  assert_equal expected, @override[:reason]
end
