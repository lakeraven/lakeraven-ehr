Feature: Provider Search and Management
  As a clinical coordinator
  I need to search for healthcare providers
  So that I can create appropriate referrals and track provider activity

  Background:
    Given the following practitioners are seeded:
      | ien | name            | specialty          | npi        | dea_number |
      | 101 | MARTINEZ,SARAH  | Cardiology         | 1234567890 | AM1234563  |
      | 102 | CHEN,JAMES      | Orthopedic Surgery | 2345678901 |            |

  Scenario: Search for provider by name
    When I search for providers with name "MARTINEZ"
    Then I should find 1 provider in the results
    And the provider results should include "MARTINEZ,SARAH"

  Scenario: Retrieve provider by IEN
    When I retrieve provider with IEN 101
    Then I should see provider "MARTINEZ,SARAH"
    And the provider details should show:
      | Field     | Value          |
      | Specialty | Cardiology     |
      | NPI       | 1234567890     |
      | DEA       | AM1234563      |

  Scenario: List all providers
    When I search for all providers
    Then I should find 2 providers in the results

  Scenario: Identify providers who can prescribe controlled substances
    When I search for providers who can prescribe controlled substances
    Then I should find 1 provider in the results
    And the provider results should include "MARTINEZ,SARAH"
    But the provider results should not include "CHEN,JAMES"

  Scenario: Search with no results
    When I search for providers with name "NONEXISTENT"
    Then I should find 0 providers in the results

  Scenario: Retrieve nonexistent provider
    When I retrieve provider with IEN 99999
    Then the provider should be nil

  Scenario: Provider has expected credentials
    When I retrieve provider with IEN 101
    Then the provider should be able to prescribe controlled substances
