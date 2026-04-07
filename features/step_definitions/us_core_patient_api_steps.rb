# frozen_string_literal: true

require "rack/test"
require "json"

# Cucumber Rack::Test wiring — minimal test client against the dummy
# app so feature scenarios can issue real HTTP requests through the
# engine routes without spinning up a Capybara browser.
module FhirRackHelpers
  include Rack::Test::Methods

  def app
    Rails.application
  end
end

World(FhirRackHelpers)

# Tenancy is established by request headers (X-Tenant-Identifier and
# X-Facility-Identifier) until SMART auth lands in #52. These step
# definitions read the current tenant/facility back out of
# Lakeraven::EHR::Current (set by the shared "the current tenant is
# ..." step from patient_search_steps.rb) and replay them as headers
# on the rack-test request, so scenarios stay declarative and don't
# have to know whether the tenant came from a header, a SMART launch,
# or anywhere else.

Given('patient {string} has identifier system {string} and value {string}') do |display_name, system, value|
  tenant = Lakeraven::EHR::Current.tenant_identifier
  patients = Lakeraven::EHR.adapter.search_patients(tenant_identifier: tenant, name: display_name)
  raise "no patient with display_name #{display_name}" if patients.empty?

  identifier = patients.first[:patient_identifier]
  Lakeraven::EHR.adapter.attach_patient_identifier(
    tenant_identifier: tenant,
    patient_identifier: identifier,
    system: system,
    value: value
  )
end

Given("a patient {string} exists in tenant {string}") do |display_name, other_tenant|
  Lakeraven::EHR.adapter.seed_patient(
    tenant_identifier: other_tenant,
    facility_identifier: "fac_main",
    display_name: display_name,
    date_of_birth: Date.new(1990, 1, 1),
    gender: "male"
  )
  @other_tenant_identifier = Lakeraven::EHR.adapter.search_patients(
    tenant_identifier: other_tenant, name: display_name
  ).first[:patient_identifier]
end

Given("the request omits the tenant header") do
  @omit_tenant_header = true
end

When("I GET the FHIR Patient with identifier of {string}") do |display_name|
  tenant = Lakeraven::EHR::Current.tenant_identifier
  patient = Lakeraven::EHR.adapter.search_patients(tenant_identifier: tenant, name: display_name).first
  raise "no patient with display_name #{display_name}" unless patient

  do_get_patient(patient[:patient_identifier])
end

When("I GET the FHIR Patient with identifier {string}") do |raw_identifier|
  do_get_patient(raw_identifier)
end

When("I GET the FHIR Patient with the tnt_other identifier of {string}") do |_display_name|
  # Send request scoped to tnt_test (background) but ask for tnt_other's patient
  do_get_patient(@other_tenant_identifier)
end

Then("the response status is {int}") do |status|
  assert_equal status, last_response.status, "body: #{last_response.body[0..500]}"
end

Then("the response Content-Type is {string}") do |content_type|
  assert_equal content_type, last_response.content_type.split(";").first
end

Then("the response body is a FHIR Patient resource") do
  assert_equal "Patient", parsed_body["resourceType"]
end

Then("the resource id matches the requested identifier") do
  assert_equal @last_requested_identifier, parsed_body["id"]
end

Then("the resource meta.profile includes {string}") do |profile|
  assert_includes parsed_body.dig("meta", "profile") || [], profile
end

Then("the resource name has family {string}") do |family|
  assert_equal family, parsed_body["name"]&.first&.[]("family")
end

Then("the resource name has given {string}") do |given|
  assert_includes parsed_body["name"]&.first&.[]("given") || [], given
end

Then("the resource gender is {string}") do |gender|
  assert_equal gender, parsed_body["gender"]
end

Then("the resource birthDate is {string}") do |birth_date|
  assert_equal birth_date, parsed_body["birthDate"]
end

Then("the resource identifier includes a value of {string} with system {string}") do |value, system|
  identifiers = parsed_body["identifier"] || []
  match = identifiers.find { |id| id["system"] == system && id["value"] == value }
  assert match, "expected identifier { system: #{system}, value: #{value} } not found in #{identifiers.inspect}"
end

Then('the response body is a FHIR OperationOutcome with severity {string} and code {string}') do |severity, code|
  assert_equal "OperationOutcome", parsed_body["resourceType"]
  issue = parsed_body["issue"]&.first
  refute_nil issue
  assert_equal severity, issue["severity"]
  assert_equal code, issue["code"]
end

# -- helpers ----------------------------------------------------------------

def do_get_patient(identifier)
  @last_requested_identifier = identifier
  headers = {}
  headers["X-Tenant-Identifier"]   = Lakeraven::EHR::Current.tenant_identifier unless @omit_tenant_header
  headers["X-Facility-Identifier"] = Lakeraven::EHR::Current.facility_identifier if Lakeraven::EHR::Current.facility_identifier
  rack_env = headers.transform_keys { |k| "HTTP_#{k.upcase.tr('-', '_')}" }
  get "/lakeraven-ehr/Patient/#{identifier}", {}, rack_env
end

def parsed_body
  @parsed_body ||= JSON.parse(last_response.body)
end

Before do
  @parsed_body = nil
  @omit_tenant_header = false
  @last_requested_identifier = nil
  @other_tenant_identifier = nil
end
