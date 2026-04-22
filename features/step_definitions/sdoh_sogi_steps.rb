# frozen_string_literal: true

Given("patient {string} has an observation with code {string} and value {string} recorded on {string}") do |_dfn, code, value, date|
  @observations ||= []
  @observations << ::OpenStruct.new(code: code, value: value, effective_date: Date.parse(date))
end

Given("the observation has category {string}") do |category|
  @observation_category = category
end

Given("patient {string} has sexual orientation {string}") do |dfn, value|
  Lakeraven::EHR::PatientSupplement.find_or_create_by!(patient_dfn: dfn.to_i) do |s|
    s.sexual_orientation = value
  end.update!(sexual_orientation: value)
  @patient = Lakeraven::EHR::Patient.find_by_dfn(dfn)
end

Given("patient {string} has gender identity {string}") do |dfn, value|
  Lakeraven::EHR::PatientSupplement.find_or_create_by!(patient_dfn: dfn.to_i) do |s|
    s.gender_identity = value
  end.update!(gender_identity: value)
  @patient = Lakeraven::EHR::Patient.find_by_dfn(dfn)
end

Then("the observation for patient {string} with code {string} should have category {string}") do |_dfn, code, category|
  actual = @observation_category || Lakeraven::EHR::SdohObservation.category_for(code)
  assert_equal category, actual
end

Then("the observation should have LOINC code {string}") do |code|
  assert Lakeraven::EHR::SdohObservation.known_code?(code)
end

Then("the observation FHIR resource should have profile {string}") do |profile|
  code = @observations&.last&.code
  actual = if @observation_category == "survey"
    Lakeraven::EHR::SdohObservation::US_CORE_SCREENING_PROFILE
  else
    Lakeraven::EHR::SdohObservation.profile_for(code)
  end
  assert_equal profile, actual
end

When("I view the FHIR Patient resource for patient {string}") do |_dfn|
  decorated = Lakeraven::EHR::PatientDecorator.new(@patient)
  @fhir_patient = decorated.to_fhir
end

Then("the Patient resource should have a sexual orientation extension with value {string}") do |value|
  ext = @fhir_patient[:extension]&.find { |e| e[:url]&.include?("sexualOrientation") }
  assert ext, "Expected sexual orientation extension"
  assert_equal value, ext[:valueString]
end

Then("the Patient resource should have a gender identity extension with value {string}") do |value|
  ext = @fhir_patient[:extension]&.find { |e| e[:url]&.include?("genderIdentity") }
  assert ext, "Expected gender identity extension"
  assert_equal value, ext[:valueString]
end

After do
  Lakeraven::EHR::PatientSupplement.delete_all
end
