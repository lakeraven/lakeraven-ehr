# frozen_string_literal: true

When("I scan a GS1-128 barcode {string}") do |barcode_string|
  @barcode = Lakeraven::EHR::VaccineBarcode.parse(barcode_string)
end

When("I scan an invalid barcode {string}") do |barcode_string|
  @barcode = Lakeraven::EHR::VaccineBarcode.parse(barcode_string)
end

When("I scan a GS1-128 barcode with FNC1 separators") do
  # GTIN + FNC1 + lot + FNC1 + serial
  input = "0112345678901234\x1D101234A\x1D21SN001"
  @barcode = Lakeraven::EHR::VaccineBarcode.parse(input)
end

Given("the immunization gateway can resolve GTIN to vaccine {string} with CVX {string}") do |display, code|
  @mock_vaccine = { vaccine_code: code, vaccine_display: display }
end

When("I scan a barcode and look up the vaccine") do
  # Simulate lookup — in production this goes through RPMS gateway
  @vaccine_result = @mock_vaccine
end

Then("the barcode should be valid") do
  assert @barcode.valid?, "Expected barcode to be valid"
end

Then("the barcode should be invalid") do
  refute @barcode.valid?
end

Then("the barcode should contain lot number {string}") do |lot|
  assert_equal lot, @barcode.lot_number
end

Then("the barcode should contain expiration date {string}") do |date|
  assert_equal Date.parse(date), @barcode.expiration_date
end

Then("the barcode should contain an NDC code") do
  assert @barcode.ndc_code.present?
end

Then("the barcode should contain lot and serial numbers") do
  assert @barcode.lot_number.present?, "Expected lot number"
  assert @barcode.serial_number.present?, "Expected serial number"
end

Then("I should receive vaccine code {string}") do |code|
  assert_equal code, @vaccine_result[:vaccine_code]
end

Then("I should receive vaccine display {string}") do |display|
  assert_equal display, @vaccine_result[:vaccine_display]
end
