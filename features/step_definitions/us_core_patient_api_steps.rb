# frozen_string_literal: true

# US Core Patient API step definitions — lakeraven-ehr
# ONC 170.315(g)(10)(i) - US Core Patient profile compliance
#
# Reuses existing steps from bulk_export_steps.rb and cqm_steps.rb:
#   - "I request GET {string} with the Bearer token"
#   - "the response status should be {int}"
#   - "the response should be a FHIR Bundle"
#   - "the response should be a FHIR OperationOutcome with code {string}"
#   - "the system is configured for FHIR API access"
#   - "I have a valid SMART token with scope {string}"

Then("the Bundle should contain at least {int} entries") do |min_count|
  body = JSON.parse(last_response.body)
  entries = body["entry"] || []
  assert entries.length >= min_count,
    "Expected at least #{min_count} entries, got #{entries.length}"
end

Then("the first patient entry should include US Core Patient profile in meta") do
  body = JSON.parse(last_response.body)
  entries = body["entry"] || []
  refute_empty entries, "Expected at least one patient entry"

  patient = entries.first["resource"]
  profiles = patient.dig("meta", "profile") || []
  us_core = profiles.any? { |p| p.include?("us-core-patient") }
  assert us_core, "Expected US Core Patient profile in meta, got: #{profiles}"
end

# "each entry should have resourceType {string}" is already defined in
# fhir_clinical_resource_steps.rb — do not redefine here.

Then("the first patient entry should include US Core race extension") do
  body = JSON.parse(last_response.body)
  entries = body["entry"] || []
  refute_empty entries, "Expected at least one patient entry"

  patient = entries.first["resource"]
  extensions = patient["extension"] || []
  race_ext = extensions.find { |e| e["url"]&.include?("us-core-race") }
  refute_nil race_ext, "Expected US Core race extension in patient"
end

Then("the race extension should contain an ombCategory coding") do
  body = JSON.parse(last_response.body)
  entries = body["entry"] || []
  patient = entries.first["resource"]
  extensions = patient["extension"] || []
  race_ext = extensions.find { |e| e["url"]&.include?("us-core-race") }
  refute_nil race_ext, "Expected US Core race extension"

  nested = race_ext["extension"] || []
  omb = nested.find { |e| e["url"] == "ombCategory" }
  refute_nil omb, "Expected ombCategory sub-extension in race extension"

  coding = omb["valueCoding"]
  refute_nil coding, "Expected valueCoding in ombCategory"
  assert coding["code"].present?, "Expected code in ombCategory valueCoding"
end

Then("the first patient entry should include US Core ethnicity extension") do
  body = JSON.parse(last_response.body)
  entries = body["entry"] || []
  refute_empty entries, "Expected at least one patient entry"

  patient = entries.first["resource"]
  extensions = patient["extension"] || []
  ethnicity_ext = extensions.find { |e| e["url"]&.include?("us-core-ethnicity") }
  refute_nil ethnicity_ext, "Expected US Core ethnicity extension in patient"
end
