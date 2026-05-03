# frozen_string_literal: true

# ServiceRequest step definitions

Given("a service request for {string} from provider {string} for patient {string}") do |service, provider, dfn|
  @service_request = Lakeraven::EHR::ServiceRequest.new(
    patient_dfn: dfn.to_i, requesting_provider_ien: provider.to_i,
    service_requested: service
  )
end

Given("a service request without a patient") do
  @service_request = Lakeraven::EHR::ServiceRequest.new(
    requesting_provider_ien: 201, service_requested: "Test"
  )
end

Given("a service request without a service from provider {string} for patient {string}") do |provider, dfn|
  @service_request = Lakeraven::EHR::ServiceRequest.new(
    patient_dfn: dfn.to_i, requesting_provider_ien: provider.to_i
  )
end

Given("a service request for {string} with status {string} from provider {string} for patient {string}") do |service, status, provider, dfn|
  @service_request = Lakeraven::EHR::ServiceRequest.new(
    patient_dfn: dfn.to_i, requesting_provider_ien: provider.to_i,
    service_requested: service, status: status
  )
end

Given("a service request for {string} with urgency {string} from provider {string} for patient {string}") do |service, urgency, provider, dfn|
  @service_request = Lakeraven::EHR::ServiceRequest.new(
    patient_dfn: dfn.to_i, requesting_provider_ien: provider.to_i,
    service_requested: service, urgency: urgency
  )
end

Given("a service request for {string} with appointment {string} from provider {string} for patient {string}") do |service, date, provider, dfn|
  @service_request = Lakeraven::EHR::ServiceRequest.new(
    patient_dfn: dfn.to_i, requesting_provider_ien: provider.to_i,
    service_requested: service, appointment_on: Date.parse(date), status: "active"
  )
end

When("I serialize the service request to FHIR") do
  @fhir = @service_request.to_fhir
end

Then("the service request should be valid") do
  assert @service_request.valid?, "Expected valid: #{@service_request.errors.full_messages}"
end

Then("the service request should be invalid") do
  refute @service_request.valid?
end

Then("the service request should be active") do
  assert @service_request.active?, "Expected active"
end

Then("the service request should be completed") do
  assert @service_request.completed?, "Expected completed"
end

Then("the service request should be urgent") do
  assert @service_request.urgent?, "Expected urgent"
end

Then("the service request should be overdue") do
  assert @service_request.overdue?, "Expected overdue"
end

Then("the service request priority should be {int}") do |expected|
  assert_equal expected, @service_request.priority
end
