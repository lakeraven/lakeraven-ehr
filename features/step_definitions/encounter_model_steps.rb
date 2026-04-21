# frozen_string_literal: true

# Encounter model step definitions.

def build_encounter(**attrs)
  defaults = { status: "finished", class_code: "AMB" }
  Lakeraven::EHR::Encounter.new(**defaults.merge(attrs))
end

# ── Creation ──

Given("an encounter with status {string} and class_code {string}") do |status, class_code|
  @encounter = build_encounter(status: status, class_code: class_code)
end

Given("an encounter with status {string} and class_code {string} and period {string} to {string}") do |status, class_code, period_start, period_end|
  @encounter = build_encounter(
    status: status, class_code: class_code,
    period_start: DateTime.parse(period_start), period_end: DateTime.parse(period_end)
  )
end

Given("an encounter with status {string} class_code {string} type_code {string} type_display {string}") do |status, class_code, type_code, type_display|
  @encounter = build_encounter(status: status, class_code: class_code, type_code: type_code, type_display: type_display)
end

Given("an encounter with status {string} class_code {string} reason_code {string} reason_display {string}") do |status, class_code, reason_code, reason_display|
  @encounter = build_encounter(status: status, class_code: class_code, reason_code: reason_code, reason_display: reason_display)
end

Given("an encounter with status {string} class_code {string} and patient_identifier {string}") do |status, class_code, patient_id|
  @encounter = build_encounter(status: status, class_code: class_code, patient_identifier: patient_id)
end

Given("an encounter with status {string} class_code {string} and practitioner_identifier {string}") do |status, class_code, prov_id|
  @encounter = build_encounter(status: status, class_code: class_code, practitioner_identifier: prov_id)
end

# ── Attribute assertions ──

Then("the encounter status should be {string}") do |expected|
  assert_equal expected, @encounter.status
end

Then("the encounter class_code should be {string}") do |expected|
  assert_equal expected, @encounter.class_code
end

Then("the encounter status_display should be {string}") do |expected|
  assert_equal expected, @encounter.status_display
end

Then("the encounter class_display should be {string}") do |expected|
  assert_equal expected, @encounter.class_display
end

Then("the encounter should be in_progress") do
  assert @encounter.in_progress?
end

Then("the encounter should not be finished") do
  refute @encounter.finished?
end

Then("the encounter should be emergency") do
  assert @encounter.emergency?
end

Then("the encounter should not be ambulatory") do
  refute @encounter.ambulatory?
end

Then("the encounter should not be valid") do
  refute @encounter.valid?
end

# ── FHIR serialization ──

Then("the FHIR resourceType should be {string}") do |expected|
  assert_equal expected, @fhir[:resourceType]
end

When("I serialize the encounter to FHIR") do
  @fhir = @encounter.to_fhir
end

Then("the FHIR meta profile should include the US Core Encounter profile") do
  assert_includes @fhir.dig(:meta, :profile),
    "http://hl7.org/fhir/us/core/StructureDefinition/us-core-encounter"
end

Then("the FHIR status should be {string}") do |expected|
  assert_equal expected, @fhir[:status]
end

Then("the FHIR class code should be {string}") do |expected|
  assert_equal expected, @fhir[:class][:code]
end

Then("the FHIR class system should be {string}") do |expected|
  assert_equal expected, @fhir[:class][:system]
end

Then("the FHIR period start should be {string}") do |expected|
  assert @fhir[:period][:start].start_with?(expected)
end

Then("the FHIR period end should be {string}") do |expected|
  assert @fhir[:period][:end].start_with?(expected)
end

Then("the FHIR type text should be {string}") do |expected|
  assert_equal expected, @fhir[:type].first[:text]
end

Then("the FHIR reasonCode text should be {string}") do |expected|
  assert_equal expected, @fhir[:reasonCode].first[:text]
end

Then("the FHIR subject reference should be {string}") do |expected|
  assert_equal expected, @fhir[:subject][:reference]
end

Then("the FHIR participant individual reference should be {string}") do |expected|
  assert_equal expected, @fhir[:participant].first[:individual][:reference]
end

# ── FHIR deserialization ──

Given("a FHIR Encounter resource with status {string} class {string} and period {string} to {string}") do |status, class_code, period_start, period_end|
  @fhir_input = {
    resourceType: "Encounter",
    status: status,
    class: {
      system: "http://terminology.hl7.org/CodeSystem/v3-ActCode",
      code: class_code
    },
    period: {
      start: period_start,
      end: period_end
    }
  }
end

When("I build an encounter from the FHIR resource") do
  @encounter = Lakeraven::EHR::Encounter.from_fhir(@fhir_input)
end
