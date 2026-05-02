# frozen_string_literal: true

# RelatedPerson step definitions

Given("a related person with relationship {string} for patient {string}") do |rel, dfn|
  @related_person = Lakeraven::EHR::RelatedPerson.new(
    patient_dfn: dfn, name: "Doe,Jane", relationship: rel, active: true
  )
end

Given("a related person without a patient") do
  @related_person = Lakeraven::EHR::RelatedPerson.new(name: "Doe,Jane", relationship: "parent")
end

Given("a related person without a name for patient {string}") do |dfn|
  @related_person = Lakeraven::EHR::RelatedPerson.new(patient_dfn: dfn, relationship: "parent")
end

Given("an active related person for patient {string}") do |dfn|
  @related_person = Lakeraven::EHR::RelatedPerson.new(
    patient_dfn: dfn, name: "Doe,Jane", relationship: "parent", active: true
  )
end

Given("an inactive related person for patient {string}") do |dfn|
  @related_person = Lakeraven::EHR::RelatedPerson.new(
    patient_dfn: dfn, name: "Doe,Jane", relationship: "parent", active: false
  )
end

Given("a related person with period from {string} to {string} for patient {string}") do |s, e, dfn|
  @related_person = Lakeraven::EHR::RelatedPerson.new(
    patient_dfn: dfn, name: "Doe,Jane", relationship: "parent",
    active: true, period_start: Date.parse(s), period_end: Date.parse(e)
  )
end

Given("a related person named {string} with relationship {string} for patient {string}") do |name, rel, dfn|
  @related_person = Lakeraven::EHR::RelatedPerson.new(
    patient_dfn: dfn, name: name, relationship: rel, active: true
  )
end

When("I serialize the related person to FHIR") do
  @fhir = @related_person.to_fhir
end

Then("the related person should be valid") do
  assert @related_person.valid?, "Expected valid: #{@related_person.errors.full_messages}"
end

Then("the related person should be invalid") do
  refute @related_person.valid?
end

Then("the relationship display should include {string}") do |text|
  display = @related_person.relationship_display || @related_person.relationship
  assert_includes display.to_s, text
end

Then("the related person should be active") do
  assert @related_person.active?, "Expected active"
end

Then("the related person should not be active") do
  refute @related_person.active?
end

Then("the related person should be within period") do
  assert @related_person.within_period?, "Expected within period"
end

Then("the related person should not be within period") do
  refute @related_person.within_period?
end

Then("the FHIR patient reference should include {string}") do |dfn|
  patient = @fhir[:patient] || @fhir[:subject]
  refute_nil patient
  assert_includes patient[:reference], dfn
end

Then("the FHIR relationship should be present") do
  rel = @fhir[:relationship]
  refute_nil rel
end

Then("the FHIR name should include {string}") do |text|
  names = @fhir[:name]
  refute_nil names
  name_text = names.is_a?(Array) ? names.map { |n| n[:text] || "#{n[:family]} #{n[:given]&.join(' ')}" }.join(" ") : names.to_s
  assert_includes name_text, text
end
