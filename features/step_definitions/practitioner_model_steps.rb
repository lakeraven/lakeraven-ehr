# frozen_string_literal: true

# Practitioner model step definitions.

def build_practitioner(**attrs)
  Lakeraven::EHR::Practitioner.new(**attrs)
end

# ── Creation ──

Given("a practitioner with name {string}") do |name|
  @practitioner = build_practitioner(name: name)
end

Given("a practitioner with first_name {string} and last_name {string}") do |first, last|
  @practitioner = build_practitioner(first_name: first, last_name: last)
end

Given("a practitioner with name {string} and npi {string}") do |name, npi|
  @practitioner = build_practitioner(name: name, npi: npi)
end

Given("a practitioner with name {string} and gender {string}") do |name, gender|
  @practitioner = build_practitioner(name: name, gender: gender)
end

Given("a practitioner with ien {int} and name {string}") do |ien, name|
  @practitioner = build_practitioner(ien: ien, name: name)
end

Given("a practitioner with name {string} and specialty {string}") do |name, specialty|
  @practitioner = build_practitioner(name: name, specialty: specialty)
end

Given("a practitioner with name {string} and phone {string}") do |name, phone|
  @practitioner = build_practitioner(name: name, phone: phone)
end

# ── Attribute assertions ──

Then("the practitioner last_name should be {string}") do |expected|
  assert_equal expected, @practitioner.last_name
end

Then("the practitioner first_name should be {string}") do |expected|
  assert_equal expected, @practitioner.first_name
end

Then("the practitioner first_name should be blank") do
  assert_nil @practitioner.first_name
end

Then("the practitioner last_name should be blank") do
  assert_nil @practitioner.last_name
end

Then("the practitioner display_name should be {string}") do |expected|
  assert_equal expected, @practitioner.display_name
end

Then("the practitioner formal_name should be {string}") do |expected|
  assert_equal expected, @practitioner.formal_name
end

Then("the practitioner name should be {string}") do |expected|
  assert_equal expected, @practitioner.name
end

Then("the practitioner npi should be {string}") do |expected|
  assert_equal expected, @practitioner.npi
end

# ── FHIR serialization ──

When("I serialize the practitioner to FHIR") do
  @fhir = @practitioner.to_fhir
end

Then("the FHIR meta profile should include the US Core Practitioner profile") do
  assert_includes @fhir.dig(:meta, :profile),
    "http://hl7.org/fhir/us/core/StructureDefinition/us-core-practitioner"
end

Then("the FHIR qualifications should include {string}") do |expected|
  texts = @fhir[:qualification]&.map { |q| q.dig(:code, :text) } || []
  assert_includes texts, expected
end

# ── FHIR deserialization ──

Given("a FHIR Practitioner resource with family {string} given {string} npi {string}") do |family, given, npi|
  @fhir_input = {
    resourceType: "Practitioner",
    name: [ { family: family, given: [ given ] } ],
    identifier: [
      { system: "http://hl7.org/fhir/sid/us-npi", value: npi }
    ]
  }
end

When("I build a practitioner from the FHIR resource") do
  @practitioner = Lakeraven::EHR::Practitioner.from_fhir(@fhir_input)
end
