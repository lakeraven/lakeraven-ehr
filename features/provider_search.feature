Feature: Provider search
  As a SMART-on-FHIR client
  I need to search for practitioners in the EHR
  So that I can resolve a provider context for referrals, signing, and orders

  Background:
    Given the EHR adapter is the in-memory mock
    And the current tenant is "tnt_test"
    And the current facility is "fac_main"
    And the following practitioners are registered at facility "fac_main":
      | display_name      | specialty            | npi        |
      | MARTINEZ,SARAH    | Cardiology           | 1234567890 |
      | CHEN,JAMES        | Orthopedic Surgery   | 2345678901 |
      | RODRIGUEZ,LISA    | Family Medicine      | 3456789012 |
    And the following practitioners are registered at facility "fac_other":
      | display_name      | specialty            | npi        |
      | OTHER,PROVIDER    | Dermatology          | 4567890123 |

  Scenario: Search by full name
    When I search for practitioners by name "MARTINEZ,SARAH"
    Then the practitioner search returns 1 practitioner
    And the result includes a practitioner with display name "MARTINEZ,SARAH"

  Scenario: Search by partial last name
    When I search for practitioners by name "MARTINEZ"
    Then the practitioner search returns 1 practitioner
    And the result includes a practitioner with display name "MARTINEZ,SARAH"

  Scenario: Search by specialty
    When I search for practitioners by specialty "Cardiology"
    Then the practitioner search returns 1 practitioner
    And the result includes a practitioner with display name "MARTINEZ,SARAH"

  Scenario: Search by NPI as FHIR Identifier
    When I search for practitioners with identifier system "http://hl7.org/fhir/sid/us-npi" and value "2345678901"
    Then the practitioner search returns 1 practitioner
    And the result includes a practitioner with display name "CHEN,JAMES"

  Scenario: List all practitioners in the current facility
    When I search for practitioners with no filter
    Then the practitioner search returns 3 practitioners

  Scenario: Search returns opaque practitioner identifiers
    When I search for practitioners by name "MARTINEZ"
    Then every practitioner result has an opaque practitioner_identifier prefixed with "pr_"
    And no practitioner result exposes a backend-native IEN

  Scenario: Empty result is a valid empty array, not an error
    When I search for practitioners by name "NONEXISTENT"
    Then the practitioner search returns 0 practitioners
    And the practitioner search succeeds without raising

  Scenario: Search is scoped to the current facility
    When I search for practitioners by name "PROVIDER"
    Then the practitioner search returns 0 practitioners

  Scenario: Search across all facilities in the tenant when no facility is set
    Given the current facility is unset
    When I search for practitioners by name "PROVIDER"
    Then the practitioner search returns 1 practitioner

  Scenario: Search fails loud when no tenant context is set
    Given the current tenant is unset
    When I search for practitioners by name "MARTINEZ"
    Then the practitioner search raises a missing-tenant-context error
