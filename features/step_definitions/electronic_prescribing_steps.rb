# frozen_string_literal: true

# ONC § 170.315(b)(3) — Electronic Prescribing step definitions
# Covers NCPDP SCRIPT generation, refill/change requests, EPCS, e-prescribing adapter routing.

# -----------------------------------------------------------------------------
# Given: medication orders and prescriptions
# -----------------------------------------------------------------------------

Given("a signed medication order for {string}") do |medication_name|
  @medication_order = Lakeraven::EHR::MedicationRequest.new(
    ien: "med-#{SecureRandom.hex(4)}",
    patient_dfn: @patient_dfn || "12345",
    requester_duz: "789",
    requester_name: "Dr. Smith",
    medication_display: medication_name,
    medication_code: ncpdp_test_rxnorm(medication_name),
    status: "active",
    intent: "order",
    dosage_instruction: "Take 1 tablet daily",
    route: "oral",
    frequency: "daily",
    dispense_quantity: 30,
    refills: 3,
    days_supply: 30,
    authored_on: Time.current
  )
end

Given("a transmitted prescription with ID {string}") do |transmission_id|
  @medication_order ||= Lakeraven::EHR::MedicationRequest.new(
    ien: "med-#{SecureRandom.hex(4)}",
    patient_dfn: @patient_dfn || "12345",
    requester_duz: "789",
    requester_name: "Dr. Smith",
    medication_display: "Lisinopril 10 MG Oral Tablet",
    medication_code: "197884",
    status: "active",
    intent: "order",
    dosage_instruction: "Take 1 tablet daily",
    route: "oral",
    frequency: "daily",
    dispense_quantity: 30,
    refills: 3,
    days_supply: 30,
    authored_on: Time.current
  )
  @transmission_id = transmission_id
end

Given("the prescription has been transmitted") do
  adapter = Lakeraven::EHR::Eprescribing::MockAdapter.new
  @erx_service = Lakeraven::EHR::EprescribingService.new(adapter: adapter)
  result = @erx_service.transmit(@medication_order, provider_duz: "789")
  @transmission_id = result.transmission_id
  @mock_adapter = adapter
end

Given("the pharmacy has requested a refill") do
  @refill_result = @erx_service.request_refill(@transmission_id, pharmacy_ncpdpid: "1234567")
end

Given("a requested medication change to {string}") do |new_medication|
  @change_medication = new_medication
  @change_medication_code = ncpdp_test_rxnorm(new_medication)
end

Given("the medication is DEA Schedule {string}") do |schedule|
  @dea_schedule = schedule
  @medication_order.instance_variable_set(:@dea_schedule, schedule)
  unless @medication_order.respond_to?(:dea_schedule)
    @medication_order.define_singleton_method(:dea_schedule) { @dea_schedule }
  end
end

# -----------------------------------------------------------------------------
# When: NCPDP SCRIPT message generation
# -----------------------------------------------------------------------------

When("an NCPDP SCRIPT NewRx message is generated") do
  @ncpdp_message = Lakeraven::EHR::NcpdpScriptGenerator.new_rx(@medication_order, prescriber: {
    duz: "789", name: "Dr. Smith", npi: "1234567890", dea: "AS1234567"
  })
  @ncpdp_doc = Nokogiri::XML(@ncpdp_message)
end

When("an NCPDP SCRIPT CancelRx message is generated with reason {string}") do |reason|
  @ncpdp_message = Lakeraven::EHR::NcpdpScriptGenerator.cancel_rx(
    @medication_order,
    transmission_id: @transmission_id,
    reason: reason,
    prescriber: { duz: "789", name: "Dr. Smith", npi: "1234567890" }
  )
  @ncpdp_doc = Nokogiri::XML(@ncpdp_message)
  @cancel_reason = reason
end

When("an NCPDP SCRIPT RxFill message is generated") do
  @ncpdp_message = Lakeraven::EHR::NcpdpScriptGenerator.rx_fill(
    @medication_order,
    transmission_id: @transmission_id,
    prescriber: { duz: "789", name: "Dr. Smith", npi: "1234567890" }
  )
  @ncpdp_doc = Nokogiri::XML(@ncpdp_message)
end

When("an NCPDP SCRIPT RxChangeRequest message is generated") do
  @ncpdp_message = Lakeraven::EHR::NcpdpScriptGenerator.rx_change_request(
    @medication_order,
    transmission_id: @transmission_id,
    new_medication: { code: @change_medication_code, display: @change_medication },
    prescriber: { duz: "789", name: "Dr. Smith", npi: "1234567890" }
  )
  @ncpdp_doc = Nokogiri::XML(@ncpdp_message)
end

When("an NCPDP SCRIPT NewRx message is generated with timing") do
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  @ncpdp_message = Lakeraven::EHR::NcpdpScriptGenerator.new_rx(@medication_order, prescriber: {
    duz: "789", name: "Dr. Smith", npi: "1234567890", dea: "AS1234567"
  })
  @generation_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
end

# When: refill/change requests

When("the pharmacy requests a refill") do
  @refill_result = @erx_service.request_refill(@transmission_id, pharmacy_ncpdpid: "1234567")
end

When("the provider approves the refill request") do
  @approval_result = @erx_service.approve_refill(@refill_result.transmission_id, provider_duz: "789")
end

When("the pharmacy requests a medication change to {string}") do |new_medication|
  @change_result = @erx_service.request_change(
    @transmission_id,
    pharmacy_ncpdpid: "1234567",
    new_medication: { code: ncpdp_test_rxnorm(new_medication), display: new_medication }
  )
end

# When: EPCS and e-prescribing adapter

When("the prescription is validated for transmission") do
  @epcs_validation = Lakeraven::EHR::EpcsValidator.validate(@medication_order, dea_schedule: @dea_schedule)
end

When("the prescription is transmitted via the e-prescribing adapter") do
  @mock_adapter = Lakeraven::EHR::Eprescribing::MockAdapter.new
  erx_service = Lakeraven::EHR::EprescribingService.new(adapter: @mock_adapter)
  @adapter_result = erx_service.transmit(@medication_order, provider_duz: "789")
end

# -----------------------------------------------------------------------------
# Then: message structure
# -----------------------------------------------------------------------------

Then("the message should be valid XML") do
  doc = Nokogiri::XML(@ncpdp_message) { |config| config.strict }
  assert doc.errors.empty?, "Expected valid XML, got errors: #{doc.errors.map(&:message)}"
end

Then("the message should have message type {string}") do |message_type|
  body_node = @ncpdp_doc.at_xpath("//Body")
  assert body_node.present?, "Expected Body element"
  type_node = body_node.children.find { |c| c.element? }
  assert_equal message_type, type_node&.name, "Expected message type #{message_type}"
end

Then("the message should include prescriber information") do
  prescriber = @ncpdp_doc.at_xpath("//Prescriber")
  assert prescriber.present?, "Expected Prescriber element"
  npi = @ncpdp_doc.at_xpath("//Prescriber//NPI")
  assert npi.present?, "Expected Prescriber NPI"
end

Then("the message should include patient information") do
  patient = @ncpdp_doc.at_xpath("//Patient")
  assert patient.present?, "Expected Patient element"
end

Then("the message should include medication details") do
  medication = @ncpdp_doc.at_xpath("//MedicationPrescribed") || @ncpdp_doc.at_xpath("//DrugDescription")
  assert medication.present?, "Expected medication details"
end

Then("the message should include the cancellation reason") do
  reason = @ncpdp_doc.at_xpath("//ReasonCode") || @ncpdp_doc.at_xpath("//Note")
  assert reason.present?, "Expected cancellation reason"
  assert reason.text.present?, "Expected reason text"
end

Then("the message should include the new medication details") do
  change = @ncpdp_doc.at_xpath("//MedicationRequested") || @ncpdp_doc.at_xpath("//RequestedMedication")
  assert change.present?, "Expected new medication details in change request"
end

# Then: refill/change workflows

Then("the refill request should be recorded") do
  assert @refill_result.success?, "Expected refill request to succeed: #{@refill_result.errors}"
  assert @refill_result.transmission_id.present?, "Expected refill transmission ID"
end

Then("the refill request status should be {string}") do |expected_status|
  if expected_status == "approved" && @approval_result
    assert_equal expected_status, @approval_result.status
  else
    assert_equal expected_status, @refill_result.status
  end
end

Then("an audit event should be recorded for the refill approval") do
  event = Lakeraven::EHR::AuditEvent.last
  assert event.present?, "Expected audit event"
  assert_match(/refill/i, event.outcome_desc)
end

Then("the change request should be recorded") do
  assert @change_result.success?, "Expected change request to succeed: #{@change_result.errors}"
end

Then("the change request status should be {string}") do |expected_status|
  assert_equal expected_status, @change_result.status
end

# Then: EPCS

Then("the prescription should require EPCS two-factor authentication") do
  assert @epcs_validation[:requires_epcs], "Expected EPCS requirement for controlled substance"
  assert @epcs_validation[:requires_two_factor], "Expected two-factor auth requirement"
end

Then("the prescription should include DEA schedule information") do
  assert @epcs_validation[:dea_schedule].present?, "Expected DEA schedule"
  assert_equal @dea_schedule, @epcs_validation[:dea_schedule]
end

# Then: e-prescribing adapter

Then("the transmission should succeed") do
  assert @adapter_result.success?, "Expected successful transmission"
end

Then("the transmission result should include a transmission ID") do
  assert @adapter_result.transmission_id.present?, "Expected transmission ID in result"
end

# Then: performance

Then("the generation should complete in under {int} seconds") do |max_seconds|
  assert @generation_elapsed < max_seconds,
    "Expected generation in under #{max_seconds}s, took #{@generation_elapsed.round(3)}s"
end

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

def ncpdp_test_rxnorm(medication_name)
  {
    "Lisinopril 10 MG Oral Tablet" => "197884",
    "Lisinopril 20 MG Oral Tablet" => "197885",
    "Metformin 500 MG Oral Tablet" => "860975",
    "Amoxicillin 500 MG Oral Capsule" => "308182",
    "Hydrocodone 5 MG Oral Tablet" => "856903"
  }[medication_name] || "000000"
end
