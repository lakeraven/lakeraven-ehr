Feature: Vaccine Barcode Scanning
  As a clinical staff member
  I need to scan vaccine vial barcodes to capture lot and NDC information
  So that I can accurately record immunization data without manual entry

  Scenario: Parse GS1-128 barcode with lot, expiration, and NDC
    When I scan a GS1-128 barcode "011234567890123417260310101234A"
    Then the barcode should be valid
    And the barcode should contain lot number "1234A"
    And the barcode should contain expiration date "2026-03-10"
    And the barcode should contain an NDC code

  Scenario: Barcode scan resolves vaccine via GTIN lookup
    Given the immunization gateway can resolve GTIN to vaccine "COVID-19" with CVX "08"
    When I scan a barcode and look up the vaccine
    Then I should receive vaccine code "08"
    And I should receive vaccine display "COVID-19"

  Scenario: Invalid barcode returns helpful validation
    When I scan an invalid barcode "not-a-barcode"
    Then the barcode should be invalid

  Scenario: Barcode with FNC1 separators parsed correctly
    When I scan a GS1-128 barcode with FNC1 separators
    Then the barcode should be valid
    And the barcode should contain lot and serial numbers
