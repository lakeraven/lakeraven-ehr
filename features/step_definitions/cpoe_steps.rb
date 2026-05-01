# frozen_string_literal: true

# CPOE step definitions
# ONC § 170.315(a)(1-3)

Given("a patient exists with DFN {string}") do |dfn|
  @patient_dfn = dfn
end

Given("a provider exists with DUZ {string}") do |duz|
  @provider_duz = duz
end

Given("the patient has an active medication {string}") do |drug_name|
  @patient_medications = [OpenStruct.new(medication_display: drug_name, medication_code: nil)]
  ensure_cpoe_medication_stubs!
end

When("the provider creates a medication order:") do |table|
  data = table.rows_hash
  ensure_cpoe_medication_stubs!

  @order_result = Lakeraven::EHR::CpoeService.create_medication_order(
    patient_dfn: @patient_dfn || "12345",
    provider_duz: @provider_duz || "789",
    medication: data["medication"],
    dosage: data["dosage"],
    route: data["route"],
    frequency: data["frequency"],
    quantity: data["quantity"]&.to_i,
    refills: data["refills"]&.to_i
  )
end

When("the provider creates a medication order for {string}") do |medication|
  ensure_cpoe_medication_stubs!

  @order_result = Lakeraven::EHR::CpoeService.create_medication_order(
    patient_dfn: @patient_dfn || "12345",
    provider_duz: @provider_duz || "789",
    medication: medication
  )
end

When("the provider creates a lab order:") do |table|
  data = table.rows_hash

  @order_result = Lakeraven::EHR::CpoeService.create_lab_order(
    patient_dfn: @patient_dfn || "12345",
    provider_duz: @provider_duz || "789",
    test_name: data["test_name"],
    test_code: data["test_code"],
    priority: data["priority"],
    clinical_reason: data["clinical_reason"]
  )
end

When("the provider creates an imaging order:") do |table|
  data = table.rows_hash

  @order_result = Lakeraven::EHR::CpoeService.create_imaging_order(
    patient_dfn: @patient_dfn || "12345",
    provider_duz: @provider_duz || "789",
    study_type: data["study_type"],
    body_site: data["body_site"],
    laterality: data["laterality"],
    clinical_reason: data["clinical_reason"],
    priority: data["priority"]
  )
end

Given("a draft medication order exists for {string}") do |medication|
  ensure_cpoe_medication_stubs!

  @order_result = Lakeraven::EHR::CpoeService.create_medication_order(
    patient_dfn: @patient_dfn || "12345",
    provider_duz: @provider_duz || "789",
    medication: medication
  )
end

Given("a draft lab order exists for {string}") do |test_name|
  @order_result = Lakeraven::EHR::CpoeService.create_lab_order(
    patient_dfn: @patient_dfn || "12345",
    provider_duz: @provider_duz || "789",
    test_name: test_name
  )
end

Given("a draft imaging order exists for {string}") do |study_type|
  @order_result = Lakeraven::EHR::CpoeService.create_imaging_order(
    patient_dfn: @patient_dfn || "12345",
    provider_duz: @provider_duz || "789",
    study_type: study_type,
    body_site: "Chest"
  )
end

When("the provider signs the order") do
  @order_result = Lakeraven::EHR::CpoeService.sign_order(
    @order_result.order,
    provider_duz: @provider_duz || "789"
  )
end

When("the provider cancels the order with reason {string}") do |reason|
  @order_result = Lakeraven::EHR::CpoeService.cancel_order(
    @order_result.order,
    reason: reason
  )
end

Then("the order should be created with status {string}") do |status|
  assert @order_result.success?, "Order creation failed: #{@order_result.errors.join(', ')}"
  assert_equal status, @order_result.order.status
end

Then("the order should reference the patient") do
  assert_equal(@patient_dfn || "12345", @order_result.order.patient_dfn)
end

Then("the order should reference the provider as requester") do
  assert_equal(@provider_duz || "789", @order_result.order.requester_duz)
end

Then("the order should include interaction alerts") do
  assert @order_result.has_interaction_alerts?, "Expected interaction alerts"
end

Then("there are no interaction alerts") do
  refute @order_result.has_interaction_alerts?
end

Then("the order status should be {string}") do |status|
  assert_equal status, @order_result.order.status
end

Then("the order status should be {string} pending review") do |status|
  assert_equal status, @order_result.order.status
end

Then("the order intent should be {string}") do |intent|
  assert_equal intent, @order_result.order.intent
end

Then("the lab order should be created with status {string}") do |status|
  assert @order_result.success?
  assert_equal status, @order_result.order.status
end

Then("the lab order category should be {string}") do |category|
  assert_equal category, @order_result.order.category
end

Then("the lab order should have priority {string}") do |priority|
  assert_equal priority, @order_result.order.priority
end

Then("the lab order status should be {string}") do |status|
  assert_equal status, @order_result.order.status
end

Then("the imaging order should be created with status {string}") do |status|
  assert @order_result.success?
  assert_equal status, @order_result.order.status
end

Then("the imaging order category should be {string}") do |category|
  assert_equal category, @order_result.order.category
end

Then("the imaging order status should be {string}") do |status|
  assert_equal status, @order_result.order.status
end

def ensure_cpoe_medication_stubs!
  meds = @patient_medications || []
  allergies = @patient_allergies || []
  Lakeraven::EHR::MedicationRequest.define_singleton_method(:for_patient) { |_dfn, **_opts| meds }
  Lakeraven::EHR::AllergyIntolerance.define_singleton_method(:for_patient) { |_dfn| allergies }
end
