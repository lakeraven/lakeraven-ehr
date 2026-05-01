# frozen_string_literal: true

# Provenance _revinclude step definitions — lakeraven-ehr
# ONC 170.315(g)(10)(i)
#
# Reuses from bulk_export_steps.rb:
#   - "I request GET {string} with the Bearer token"
#   - "the response status should be {int}"
#   - "the response should be a FHIR OperationOutcome with code {string}"
# Reuses from cqm_steps.rb:
#   - "the system is configured for FHIR API access"
#   - "I have a valid SMART token with scope {string}"
#   - "the response should be a FHIR Bundle"

Given("provenance records exist for patient {string}") do |patient_dfn|
  store = Lakeraven::EHR::ProvenanceStore.instance
  store.add(Lakeraven::EHR::Provenance.new(
    target_type: "Patient",
    target_id: "rpms-#{patient_dfn}",
    recorded: Time.current,
    activity: "CREATE",
    agent_type: "author",
    agent_who_type: "Practitioner",
    agent_who_id: "rpms-101"
  ))
end

Then("the Bundle should contain Provenance entries with search mode {string}") do |mode|
  body = JSON.parse(last_response.body)
  entries = body["entry"] || []
  provenance_entries = entries.select do |e|
    e.dig("resource", "resourceType") == "Provenance" ||
      e.dig("search", "mode") == mode
  end
  refute_empty provenance_entries,
    "Expected Provenance entries with search mode '#{mode}' in Bundle"
end

Then("the Bundle should not contain Provenance entries") do
  body = JSON.parse(last_response.body)
  entries = body["entry"] || []
  provenance_entries = entries.select do |e|
    e.dig("resource", "resourceType") == "Provenance"
  end
  assert_empty provenance_entries, "Expected no Provenance entries in Bundle"
end

Before("@onc") do
  Lakeraven::EHR::ProvenanceStore.instance.clear!
end
