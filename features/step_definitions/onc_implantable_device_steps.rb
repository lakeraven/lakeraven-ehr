# frozen_string_literal: true

# ONC § 170.315(a)(14) — Implantable Device List step definitions
# Covers UDI parsing, device list display, GUDID lookup, status changes.
#
# Note: "a patient exists with DFN {string}" step is defined in cpoe_steps.rb

require "ostruct"

# -----------------------------------------------------------------------------
# UDI Parsing
# -----------------------------------------------------------------------------

When("UDI {string} is parsed") do |udi_string|
  @parsed_udi = Lakeraven::EHR::UdiParser.parse(udi_string)
end

Then("the parsed UDI should include device identifier {string}") do |di|
  assert_equal di, @parsed_udi[:device_identifier],
    "Expected DI '#{di}', got '#{@parsed_udi[:device_identifier]}'"
end

Then("the parsed UDI should include expiration date {string}") do |date_str|
  assert_equal date_str, @parsed_udi[:expiration_date]&.iso8601,
    "Expected expiration '#{date_str}', got '#{@parsed_udi[:expiration_date]}'"
end

Then("the parsed UDI should include lot number {string}") do |lot|
  assert_equal lot, @parsed_udi[:lot_number],
    "Expected lot '#{lot}', got '#{@parsed_udi[:lot_number]}'"
end

Then("the parsed UDI should include serial number {string}") do |serial|
  assert_equal serial, @parsed_udi[:serial_number],
    "Expected serial '#{serial}', got '#{@parsed_udi[:serial_number]}'"
end

Then("the parsed UDI should include manufacturing date {string}") do |date_str|
  assert_equal date_str, @parsed_udi[:manufacture_date]&.iso8601,
    "Expected manufacture date '#{date_str}', got '#{@parsed_udi[:manufacture_date]}'"
end

Then("the parsed UDI should have no lot number") do
  assert_nil @parsed_udi[:lot_number], "Expected no lot number"
end

Then("the parsed UDI should have no serial number") do
  assert_nil @parsed_udi[:serial_number], "Expected no serial number"
end

# -----------------------------------------------------------------------------
# Device List Display
# -----------------------------------------------------------------------------

Given("the patient has implantable devices with full UDI data") do
  Lakeraven::EHR::Device.define_singleton_method(:for_patient) do |_dfn, **_opts|
    [
      Lakeraven::EHR::Device.new(
        ien: "7001", patient_dfn: "12345",
        udi_carrier: "(01)00844588003288(17)141120(10)ALC110(21)SN12345",
        udi_device_identifier: "00844588003288",
        status: "active", device_name: "Dual-Chamber Pacemaker",
        manufacturer: "Medtronic", model_number: "PM3000",
        serial_number: "SN12345", lot_number: "ALC110",
        manufacture_date: Date.new(2024, 1, 15),
        expiration_date: Date.new(2034, 1, 15),
        type_code: "14106009", type_display: "Cardiac pacemaker, device",
        distinct_identifier: "D-PM3000-001"
      )
    ]
  end
end

When("the implantable device list is retrieved for the patient") do
  @device_list = Lakeraven::EHR::Device.for_patient(@patient_dfn || "12345")
  @device_fhir_list = @device_list.map(&:to_fhir)
end

Then("each device should include the UDI string") do
  @device_list.each do |d|
    assert d.udi_carrier.present?, "Expected UDI carrier string on device #{d.ien}"
  end
end

Then("each device should include the device identifier") do
  @device_list.each do |d|
    assert d.udi_device_identifier.present?, "Expected device identifier on device #{d.ien}"
  end
end

Then("each device should include manufacturer information") do
  @device_list.each do |d|
    assert d.manufacturer.present?, "Expected manufacturer on device #{d.ien}"
  end
end

Then("each device should include lot and serial numbers") do
  @device_list.each do |d|
    assert d.lot_number.present?, "Expected lot number on device #{d.ien}"
    assert d.serial_number.present?, "Expected serial number on device #{d.ien}"
  end
end

Then("each device should include manufacture and expiration dates") do
  @device_list.each do |d|
    assert d.manufacture_date.present?, "Expected manufacture date on device #{d.ien}"
    assert d.expiration_date.present?, "Expected expiration date on device #{d.ien}"
  end
end

Then("each device should include a device description") do
  @device_list.each do |d|
    assert d.device_name.present?, "Expected device name/description on device #{d.ien}"
  end
end

Then("each device should include a SNOMED device type") do
  @device_fhir_list.each do |fhir|
    assert fhir[:type].present?, "Expected type on FHIR device"
    coding = fhir[:type][:coding]&.first
    assert coding.present?, "Expected type coding"
    assert_equal "http://snomed.info/sct", coding[:system]
  end
end

# -----------------------------------------------------------------------------
# FDA GUDID Lookup
# -----------------------------------------------------------------------------

When("FDA GUDID is queried for device identifier {string}") do |di|
  @gudid_result = Lakeraven::EHR::GudidLookupService.lookup(di)
end

Then("the GUDID result should include the device description") do
  assert @gudid_result[:device_description].present?,
    "Expected device description from GUDID"
end

Then("the GUDID result should include the company name") do
  assert @gudid_result[:company_name].present?,
    "Expected company name from GUDID"
end

Then("the GUDID result should include MRI safety information") do
  assert @gudid_result.key?(:mri_safety),
    "Expected MRI safety information from GUDID"
end

# -----------------------------------------------------------------------------
# Device Status
# -----------------------------------------------------------------------------

Given("the patient has an active implantable device") do
  @test_device = Lakeraven::EHR::Device.new(
    ien: "7050", patient_dfn: "12345",
    udi_carrier: "(01)00844588003288(17)141120(10)LOT99(21)SER99",
    udi_device_identifier: "00844588003288",
    status: "active", device_name: "Cardiac Pacemaker",
    manufacturer: "Medtronic", model_number: "PM2000",
    serial_number: "SER99", lot_number: "LOT99",
    type_code: "14106009", type_display: "Cardiac pacemaker, device"
  )
  test_device = @test_device
  Lakeraven::EHR::Device.define_singleton_method(:for_patient) { |_dfn, **_opts| [ test_device ] }
end

When("the device status is changed to {string}") do |new_status|
  @test_device.status = new_status
end

Then("the device status should be {string}") do |expected_status|
  assert_equal expected_status, @test_device.status
end

Given("the patient has active and inactive devices") do
  @active_device = Lakeraven::EHR::Device.new(
    ien: "7060", patient_dfn: "12345",
    device_name: "Active Pacemaker", status: "active",
    udi_carrier: "(01)00844588003288", udi_device_identifier: "00844588003288"
  )
  @inactive_device = Lakeraven::EHR::Device.new(
    ien: "7061", patient_dfn: "12345",
    device_name: "Removed Stent", status: "inactive",
    udi_carrier: "(01)00844588009999", udi_device_identifier: "00844588009999"
  )
  all_devices = [ @active_device, @inactive_device ]
  Lakeraven::EHR::Device.define_singleton_method(:for_patient) do |_dfn, status: nil|
    status.present? ? all_devices.select { |d| d.status == status } : all_devices
  end
end

When("the implantable device list is retrieved with status {string}") do |status|
  @device_list = Lakeraven::EHR::Device.for_patient(@patient_dfn || "12345", status: status)
end

Then("only active devices should be returned") do
  @device_list.each do |d|
    assert_equal "active", d.status, "Expected only active devices, got '#{d.status}'"
  end
  assert @device_list.any?, "Expected at least one active device"
end

# -----------------------------------------------------------------------------
# FHIR Compliance
# -----------------------------------------------------------------------------

Then("each device FHIR resource should declare the US Core Implantable Device profile") do
  @device_fhir_list = @device_list.map(&:to_fhir) unless @device_fhir_list
  @device_fhir_list.each do |fhir|
    assert fhir[:meta].present?, "Expected meta on FHIR device"
    assert_includes fhir[:meta][:profile],
      "http://hl7.org/fhir/us/core/StructureDefinition/us-core-implantable-device",
      "Expected US Core Implantable Device profile"
  end
end

Given("the patient has a device with distinct identifier {string}") do |distinct_id|
  device = Lakeraven::EHR::Device.new(
    ien: "7070", patient_dfn: "12345",
    device_name: "Test Device", status: "active",
    udi_carrier: "(01)00844588003288", udi_device_identifier: "00844588003288",
    distinct_identifier: distinct_id
  )
  Lakeraven::EHR::Device.define_singleton_method(:for_patient) { |_dfn, **_opts| [ device ] }
end

Then("the FHIR device should include distinct identifier {string}") do |distinct_id|
  fhir = @device_fhir_list.first
  assert_equal distinct_id, fhir[:distinctIdentifier],
    "Expected distinctIdentifier '#{distinct_id}'"
end
