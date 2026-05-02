# frozen_string_literal: true

# FHIR Bundle import step definitions

def build_fhir_bundle(entries)
  {
    "resourceType" => "Bundle",
    "type" => "collection",
    "entry" => entries.map { |r| { "resource" => r } }
  }.to_json
end

Given("a FHIR Bundle JSON with an AllergyIntolerance for patient {string}") do |dfn|
  @bundle_json = build_fhir_bundle([
    {
      "resourceType" => "AllergyIntolerance",
      "patient" => { "reference" => "Patient/#{dfn}" },
      "code" => { "text" => "Penicillin", "coding" => [{ "code" => "7980" }] },
      "clinicalStatus" => { "coding" => [{ "code" => "active" }] }
    }
  ])
end

Given("a FHIR Bundle JSON with a Condition for patient {string}") do |dfn|
  @bundle_json = build_fhir_bundle([
    {
      "resourceType" => "Condition",
      "subject" => { "reference" => "Patient/#{dfn}" },
      "code" => { "text" => "Type 2 Diabetes", "coding" => [{ "code" => "E11.9", "system" => "http://hl7.org/fhir/sid/icd-10-cm" }] },
      "clinicalStatus" => { "coding" => [{ "code" => "active" }] }
    }
  ])
end

Given("a FHIR Bundle JSON with a MedicationRequest for patient {string}") do |dfn|
  @bundle_json = build_fhir_bundle([
    {
      "resourceType" => "MedicationRequest",
      "subject" => { "reference" => "Patient/#{dfn}" },
      "medicationCodeableConcept" => { "text" => "Metformin 500mg", "coding" => [{ "code" => "860975" }] },
      "status" => "active"
    }
  ])
end

Given("a FHIR Bundle JSON with allergies, conditions, and medications for patient {string}") do |dfn|
  @bundle_json = build_fhir_bundle([
    {
      "resourceType" => "AllergyIntolerance",
      "patient" => { "reference" => "Patient/#{dfn}" },
      "code" => { "text" => "Penicillin" },
      "clinicalStatus" => { "coding" => [{ "code" => "active" }] }
    },
    {
      "resourceType" => "Condition",
      "subject" => { "reference" => "Patient/#{dfn}" },
      "code" => { "text" => "Hypertension" },
      "clinicalStatus" => { "coding" => [{ "code" => "active" }] }
    },
    {
      "resourceType" => "MedicationRequest",
      "subject" => { "reference" => "Patient/#{dfn}" },
      "medicationCodeableConcept" => { "text" => "Lisinopril 10mg" },
      "status" => "active"
    }
  ])
end

Given("invalid JSON input") do
  @bundle_json = "not valid json {{"
end

Given("a FHIR JSON that is not a Bundle") do
  @bundle_json = { "resourceType" => "Patient", "id" => "1" }.to_json
end

When("I import the bundle for patient {string} as clinician {string}") do |dfn, duz|
  service = Lakeraven::EHR::ClinicalReconciliationService.new
  @import_result = service.import_from_fhir_bundle(
    patient_dfn: dfn, clinician_duz: duz, json_string: @bundle_json
  )
end

Then("the bundle import should succeed") do
  assert @import_result.success?, "Expected import to succeed, errors: #{@import_result.errors}"
end

Then("the bundle import should fail") do
  refute @import_result.success?, "Expected import to fail"
end

Then("the bundle import error should include {string}") do |text|
  errors = @import_result.errors.join(", ")
  assert_includes errors, text, "Expected error '#{text}' in: #{errors}"
end
