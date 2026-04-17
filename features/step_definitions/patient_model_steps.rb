# frozen_string_literal: true

# Patient model step definitions.

def build_patient(**attrs)
  defaults = { sex: "M" }
  Lakeraven::EHR::Patient.new(**defaults.merge(attrs))
end

# ── Creation ──

Given("a patient with name {string}") do |name|
  @patient = build_patient(name: name)
end

Given("a patient with first_name {string} and last_name {string}") do |first, last|
  @patient = build_patient(first_name: first, last_name: last)
end

Given("a patient with dob {string}") do |dob|
  @patient = build_patient(name: "TEST,PATIENT", dob: Date.parse(dob))
end

Given("a patient with name {string} and dob {string} and sex {string}") do |name, dob, sex|
  @patient = build_patient(name: name, dob: Date.parse(dob), sex: sex)
end

Given("a patient with dfn {int} and ssn {string}") do |dfn, ssn|
  @patient = build_patient(name: "TEST,PATIENT", dfn: dfn, ssn: ssn)
end

Given("a patient with address {string} city {string} state {string} zip {string} phone {string}") do |addr, city, state, zip, phone|
  @patient = build_patient(name: "TEST,PATIENT", address_line1: addr,
    city: city, state: state, zip_code: zip, phone: phone)
end

Given("a patient with race {string}") do |race|
  @patient = build_patient(name: "TEST,PATIENT", race: race)
end

Given("a patient with name {string} and sex {string}") do |name, sex|
  @patient = build_patient(name: name, sex: sex)
end

Given("a patient with tribal_affiliation {string}") do |value|
  @patient = build_patient(name: "TEST,PATIENT", tribal_affiliation: value)
end

Given("a patient with tribal_enrollment_number {string}") do |value|
  @patient = build_patient(name: "TEST,PATIENT", tribal_enrollment_number: value)
end

Given("a patient with sexual_orientation {string}") do |value|
  @patient = build_patient(name: "TEST,PATIENT", sexual_orientation: value)
end

Given("a patient with gender_identity {string}") do |value|
  @patient = build_patient(name: "TEST,PATIENT", gender_identity: value)
end

# ── Attribute assertions ──

Then("the patient last_name should be {string}") do |expected|
  assert_equal expected, @patient.last_name
end

Then("the patient first_name should be {string}") do |expected|
  assert_equal expected, @patient.first_name
end

Then("the patient display_name should be {string}") do |expected|
  assert_equal expected, @patient.display_name
end

Then("the patient formal_name should be {string}") do |expected|
  assert_equal expected, @patient.formal_name
end

Then("the patient name should be {string}") do |expected|
  assert_equal expected, @patient.name
end

Then("the patient born_on should be {string}") do |expected|
  assert_equal Date.parse(expected), @patient.born_on
end

# ── FHIR serialization ──

When("I serialize the patient to FHIR") do
  @fhir = @patient.to_fhir
end

Then("the FHIR resourceType should be {string}") do |expected|
  assert_equal expected, @fhir[:resourceType]
end

Then("the FHIR gender should be {string}") do |expected|
  assert_equal expected, @fhir[:gender]
end

Then("the FHIR birthDate should be {string}") do |expected|
  assert_equal expected, @fhir[:birthDate]
end

Then("the FHIR name family should be {string}") do |expected|
  assert_equal expected, @fhir[:name].first[:family]
end

Then("the FHIR name given should include {string}") do |expected|
  assert_includes @fhir[:name].first[:given], expected
end

Then("the FHIR identifiers should include system {string} with value {string}") do |system, value|
  match = @fhir[:identifier].find { |id| id[:system] == system && id[:value] == value }
  refute_nil match, "expected identifier with system=#{system} value=#{value} in #{@fhir[:identifier]}"
end

Then("the FHIR address line should be {string}") do |expected|
  assert_equal expected, @fhir[:address].first[:line].first
end

Then("the FHIR address city should be {string}") do |expected|
  assert_equal expected, @fhir[:address].first[:city]
end

Then("the FHIR telecom value should be {string}") do |expected|
  assert_equal expected, @fhir[:telecom].first[:value]
end

# ── Extension assertions ──

Then("the FHIR extensions should include a US Core race extension") do
  url = "http://hl7.org/fhir/us/core/StructureDefinition/us-core-race"
  @race_ext = @fhir[:extension].find { |e| e[:url] == url }
  refute_nil @race_ext, "expected US Core race extension"
end

Then("the race ombCategory code should be {string}") do |expected|
  omb = @race_ext[:extension].find { |e| e[:url] == "ombCategory" }
  refute_nil omb, "expected ombCategory sub-extension"
  assert_equal expected, omb[:valueCoding][:code]
end

Then("the FHIR extensions should include a US Core ethnicity extension") do
  url = "http://hl7.org/fhir/us/core/StructureDefinition/us-core-ethnicity"
  @eth_ext = @fhir[:extension].find { |e| e[:url] == url }
  refute_nil @eth_ext, "expected US Core ethnicity extension"
end

Then("the ethnicity text should be {string}") do |expected|
  text = @eth_ext[:extension].find { |e| e[:url] == "text" }
  assert_equal expected, text[:valueString]
end

Then("the FHIR extensions should include url {string}") do |url|
  match = @fhir[:extension].find { |e| e[:url] == url }
  refute_nil match, "expected extension with url=#{url}"
end

# ── Deserialization ──

Given("a FHIR Patient resource with family {string} given {string} gender {string} birthDate {string}") do |family, given, gender, birth_date|
  @fhir_input = {
    resourceType: "Patient",
    name: [ { family: family, given: [ given ] } ],
    gender: gender,
    birthDate: birth_date
  }
end

When("I extract attributes from the FHIR resource") do
  @extracted = Lakeraven::EHR::FHIR::PatientDeserializer.call(@fhir_input)
end

Then("the extracted name should be {string}") do |expected|
  assert_equal expected, @extracted[:name]
end

Then("the extracted sex should be {string}") do |expected|
  assert_equal expected, @extracted[:sex]
end

Then("the extracted dob should be {string}") do |expected|
  assert_equal Date.parse(expected), @extracted[:dob]
end
