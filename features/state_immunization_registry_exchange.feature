Feature: State Immunization Information System Exchange (Ulster County RFP §2.2.4, §2.2.18)
  As a healthcare provider
  I need bidirectional immunization data exchange with the state IIS
  So that patient vaccination records stay synchronized with the state registry

  Background:
    Given the following patients exist:
      | dfn | first_name | last_name | dob        | sex |
      | 1   | Alice      | Anderson  | 1980-05-15 | F   |
      | 2   | Bob        | Brown     | 1975-08-20 | M   |

  # ==========================================================================
  # OUTBOUND: Send immunizations to state IIS via RPMS HL7 VXU
  # ==========================================================================

  Scenario: Send patient immunizations to state IIS
    Given state IIS exchange is enabled
    And patient "1" has immunizations on file
    When I send immunizations for patient "1" to the state IIS
    Then the state IIS exchange should succeed
    And the exchange result should indicate immunizations were transmitted

  Scenario: Send immunizations when state IIS is disabled
    Given state IIS exchange is disabled
    When I send immunizations for patient "1" to the state IIS
    Then the state IIS exchange should fail
    And the exchange error should mention "disabled"

  # ==========================================================================
  # INBOUND: Query state IIS for patient immunization history
  # ==========================================================================

  Scenario: Query state IIS for patient immunization history
    Given state IIS exchange is enabled
    When I query the state IIS for patient "1" immunization history
    Then the state IIS exchange should succeed
    And the exchange result should contain immunization records

  Scenario: Query returns no records for unknown patient
    Given state IIS exchange is enabled
    When I query the state IIS for patient "999" immunization history
    Then the state IIS exchange should succeed
    And the exchange result should contain no immunization records

  # ==========================================================================
  # RESPONSE PROCESSING: Handle inbound HL7 RSP messages
  # ==========================================================================

  Scenario: Process pending state IIS responses
    Given state IIS exchange is enabled
    And there are pending state IIS responses
    When I process pending state IIS responses
    Then the state IIS exchange should succeed
    And the exchange result should indicate responses were processed

  # ==========================================================================
  # SYNC: Full bidirectional sync for a patient
  # ==========================================================================

  Scenario: Full sync queries and processes responses for a patient
    Given state IIS exchange is enabled
    When I sync patient "1" with the state IIS
    Then the state IIS exchange should succeed
    And the exchange result should include query and processing results

  # ==========================================================================
  # DEDUPLICATION: Avoid duplicate immunization records
  # ==========================================================================

  Scenario: Deduplication prevents duplicate immunization entries
    Given state IIS exchange is enabled
    And patient "1" has a local immunization for "COVID-19" on "2024-01-15"
    And the state IIS returns an immunization for "COVID-19" on "2024-01-15"
    When I sync patient "1" with the state IIS
    Then no duplicate immunizations should be created

  # ==========================================================================
  # ERROR HANDLING
  # ==========================================================================

  Scenario: RPMS connection failure handled gracefully
    Given state IIS exchange is enabled
    And the RPMS connection is unavailable for the state IIS
    When I send immunizations for patient "1" to the state IIS
    Then the state IIS exchange should fail
    And the exchange error should mention "connection"

  Scenario: Configuration error handled gracefully
    Given state IIS exchange is enabled
    But state IIS facility code is not configured
    When I send immunizations for patient "1" to the state IIS
    Then the state IIS exchange should fail
    And the exchange error should mention "configuration"

  # ==========================================================================
  # ADAPTER SELECTION
  # ==========================================================================

  Scenario: Mock adapter used in test environment
    Given state IIS exchange is enabled
    Then the state IIS adapter should be the mock adapter

  Scenario: Connection status check
    Given state IIS exchange is enabled
    When I check state IIS connection status
    Then the connection status should indicate the adapter is available
