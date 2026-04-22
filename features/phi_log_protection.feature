Feature: PHI Log Protection
  As a HIPAA-compliant system
  Log statements should not contain raw PHI identifiers
  So that patient data is protected per 45 CFR 164.312(b)

  Scenario: Service logs contain hashed identifiers not raw DFNs
    Given the eligibility service processes a request for patient DFN "12345"
    Then the log output should contain "patient_id_hash"
    And the log output should not contain "patient_dfn"
    And the log output should not contain the raw value "12345"

  Scenario: PHR controller source does not contain raw DFN logging
    Then the PHR controller should not interpolate raw DFN into log messages
