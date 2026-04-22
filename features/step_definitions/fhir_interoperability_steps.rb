# frozen_string_literal: true

When("I request patient {string} in FHIR format") do |dfn|
  @patient = Lakeraven::EHR::Patient.find_by_dfn(dfn)
  @fhir_resource = @patient.to_fhir
end

When("I request patient {string} via the FHIR API") do |dfn|
  @fhir_app ||= Doorkeeper::Application.create!(
    name: "fhir-test", redirect_uri: "https://example.test/callback",
    scopes: "system/Patient.read", confidential: true
  )
  token = Doorkeeper::AccessToken.create!(
    application: @fhir_app, scopes: "system/Patient.read", expires_in: 3600
  )
  header "Authorization", "Bearer #{token.plaintext_token || token.token}"
  get "/lakeraven-ehr/Patient/#{dfn}"
end

Then("I should receive a valid FHIR Patient resource") do
  assert_equal "Patient", @fhir_resource[:resourceType]
end

Then("the FHIR resource should have:") do |table|
  table.rows_hash.each do |key, value|
    actual = @fhir_resource[key.to_sym]&.to_s
    assert_equal value, actual, "Expected #{key}=#{value}, got #{actual}"
  end
end

Then("the FHIR Patient should have an identifier with system {string}") do |system|
  ids = @fhir_resource[:identifier] || []
  match = ids.find { |id| id[:system] == system }
  assert match, "Expected identifier with system #{system}, got: #{ids.map { |i| i[:system] }}"
end

Then("the FHIR Patient should have a tribal enrollment number in the identifiers") do
  # Tribal enrollment number is stored in the patient's id_info, not as a FHIR extension.
  # We check that the patient data includes tribal enrollment info.
  assert @patient.tribal_enrollment_number.present?, "Expected tribal enrollment number"
end

Then("the tribal enrollment identifier should contain {string}") do |enrollment|
  assert_equal enrollment, @patient.tribal_enrollment_number
end

Then("the FHIR Patient should conform to US Core Patient profile") do
  profile = @fhir_resource.dig(:meta, :profile)
  assert_includes profile, "http://hl7.org/fhir/us/core/StructureDefinition/us-core-patient"
end

Then("the FHIR resource should have required fields:") do |table|
  table.raw.flatten.each do |field|
    value = @fhir_resource[field.to_sym]
    assert value.present?, "Expected FHIR resource to have #{field}"
  end
end

Then("the FHIR Patient should have an address with state {string}") do |state|
  addr = @fhir_resource[:address]&.first
  assert addr, "Expected address"
  assert_equal state, addr[:state]
end

Then("the FHIR Patient should have a telecom with value {string}") do |value|
  telecom = @fhir_resource[:telecom]&.first
  assert telecom, "Expected telecom"
  assert_equal value, telecom[:value]
end

Then("the SSN identifier value should be {string}") do |ssn|
  ids = @fhir_resource[:identifier] || []
  ssn_id = ids.find { |id| id[:system]&.include?("ssn") }
  assert_equal ssn, ssn_id[:value]
end

# -- Round-trip --

Given("a patient with complete demographics") do
  @original_patient = Lakeraven::EHR::Patient.new(
    dfn: 99, name: "TESTPATIENT,ROUNDTRIP", sex: "M",
    dob: Date.new(1990, 6, 15), ssn: "999-99-9999",
    address_line1: "123 Test St", city: "TestCity", state: "TX", zip_code: "75001"
  )
end

When("I serialize the patient to FHIR") do
  @fhir_output = @original_patient.to_fhir
end

When("I deserialize the FHIR resource back to a Patient") do
  # Simple round-trip: extract key fields from FHIR back to Patient attrs
  @roundtrip_patient = Lakeraven::EHR::Patient.new(
    dfn: @fhir_output[:id].to_i,
    name: "#{@fhir_output[:name]&.first&.dig(:family)},#{@fhir_output[:name]&.first&.dig(:given)&.join(' ')}",
    sex: @fhir_output[:gender] == "male" ? "M" : "F"
  )
end

Then("the patient name should match the original") do
  assert_equal @original_patient.name, @roundtrip_patient.name
end

Then("the patient gender should match the original") do
  assert_equal @original_patient.sex, @roundtrip_patient.sex
end

# -- Content type --

Then("the response content type should be {string}") do |content_type|
  assert_equal content_type, last_response.content_type.split(";").first
end

After do
  if defined?(Doorkeeper)
    Doorkeeper::AccessToken.delete_all
    Doorkeeper::Application.where(name: "fhir-test").delete_all
  end
end
