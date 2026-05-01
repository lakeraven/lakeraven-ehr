@onc
Feature: Implantable Device List
  As a clinical provider
  I want to record, parse, and display implantable device information
  So that I can safely manage patients with implanted devices

  ONC § 170.315(a)(14) — Implantable Device List

  Background:
    Given a patient exists with DFN "12345"

  # =============================================================================
  # UDI PARSING — (a)(14) record UDI and parse into components
  # =============================================================================

  Scenario: Parse GS1 UDI into all required components
    When UDI "(01)00844588003288(17)141120(10)7654321D(21)10987654d432" is parsed
    Then the parsed UDI should include device identifier "00844588003288"
    And the parsed UDI should include expiration date "2014-11-20"
    And the parsed UDI should include lot number "7654321D"
    And the parsed UDI should include serial number "10987654d432"

  Scenario: Parse UDI with manufacturing date
    When UDI "(01)00844588003288(11)191015(17)291015(10)LOTA(21)SER001" is parsed
    Then the parsed UDI should include manufacturing date "2019-10-15"
    And the parsed UDI should include expiration date "2029-10-15"

  Scenario: Parse UDI with only device identifier
    When UDI "(01)00844588003288" is parsed
    Then the parsed UDI should include device identifier "00844588003288"
    And the parsed UDI should have no lot number
    And the parsed UDI should have no serial number

  # =============================================================================
  # DEVICE LIST DISPLAY — (a)(14) display implantable device list
  # =============================================================================

  Scenario: Device list includes all UDI components
    Given the patient has implantable devices with full UDI data
    When the implantable device list is retrieved for the patient
    Then each device should include the UDI string
    And each device should include the device identifier
    And each device should include manufacturer information
    And each device should include lot and serial numbers
    And each device should include manufacture and expiration dates

  Scenario: Device list includes device description and type
    Given the patient has implantable devices with full UDI data
    When the implantable device list is retrieved for the patient
    Then each device should include a device description
    And each device should include a SNOMED device type

  # =============================================================================
  # FDA GUDID LOOKUP — (a)(14) access GUDID using device identifier
  # =============================================================================

  Scenario: Look up device in FDA GUDID by device identifier
    When FDA GUDID is queried for device identifier "00844588003288"
    Then the GUDID result should include the device description
    And the GUDID result should include the company name
    And the GUDID result should include MRI safety information

  # =============================================================================
  # DEVICE STATUS — (a)(14) change status of device record
  # =============================================================================

  Scenario: Change device status from active to inactive
    Given the patient has an active implantable device
    When the device status is changed to "inactive"
    Then the device status should be "inactive"

  Scenario: Device list can be filtered by status
    Given the patient has active and inactive devices
    When the implantable device list is retrieved with status "active"
    Then only active devices should be returned

  # =============================================================================
  # FHIR COMPLIANCE — US Core Implantable Device profile
  # =============================================================================

  Scenario: FHIR Device includes US Core profile
    Given the patient has an active implantable device
    When the implantable device list is retrieved for the patient
    Then each device FHIR resource should declare the US Core Implantable Device profile

  Scenario: FHIR Device includes distinct identifier
    Given the patient has a device with distinct identifier "D12345"
    When the implantable device list is retrieved for the patient
    Then the FHIR device should include distinct identifier "D12345"
