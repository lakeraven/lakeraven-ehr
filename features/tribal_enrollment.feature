Feature: Tribal Enrollment Management
  As a healthcare provider at an IHS facility
  I need to see patient tribal enrollment information as RPMS actually records it
  So that staff act on real determinations, never on fabricated ones

  Migrated for rpms-rpc 0.3.0 (#235): tribal reads are real DDR FileMan reads
  over #9000001 / #9999999.03 / #9999999.22. The old placeholder shapes —
  ACTIVE/INACTIVE enrollment "status", a per-patient service-unit read, and a
  tribe code parsed out of the enrollment number — have no RPMS source and are
  gone. Eligibility FAILS CLOSED: the raw eligibility_status set code (I/D/C/P)
  is surfaced for transparency, but no status resolves to "eligible" until the
  compliance-owned mapping is signed off (#520).

  Background:
    Given the following patients exist:
      | dfn | first_name | last_name | dob        | sex | ssn         | tribal_enrollment | tribal_affiliation                | service_area |
      | 1   | Alice      | Anderson  | 1980-05-15 | F   | 111-11-1111 | EXNH-12345        | Example Native Health (EXNH)      | Anchorage    |
      | 2   | Bob        | Brown     | 1975-08-20 | M   | 222-22-2222 | CN-67890          | Painted Sky Nation                | Painted Sky  |
      | 4   | Diana      | Davis     | 1985-12-01 | F   | 444-44-4444 |                   |                                   | Portland     |

  Scenario: View patient tribal enrollment details
    Given the enrollment read for patient "1" returns:
      | enrollment_number  | EXNH-12345                   |
      | tribe_ien          | 100                          |
      | tribe_name         | Example Native Health (EXNH) |
      | eligibility_status | I                            |
      | classification     | Direct                       |
      | community          | Anchorage                    |
    When I request tribal enrollment details for patient "1"
    Then I should see tribal enrollment information:
      | enrollment_number | EXNH-12345                   |
      | tribe_name        | Example Native Health (EXNH) |
      | tribe_ien         | 100                          |

  Scenario: Enrollment-number validation is a syntactic format check
    Given the server accepts enrollment number "EXNH-12345" as internal "12345"
    When I validate tribal enrollment number "EXNH-12345"
    Then the enrollment should be valid

  Scenario: A malformed enrollment number reports invalid
    Given the server rejects enrollment number "INVALID"
    When I validate tribal enrollment number "INVALID"
    Then the enrollment should not be valid

  Scenario: A present eligibility status never resolves to eligible (fail closed)
    Given the eligibility read for patient "1" returns status "I" classified "Direct"
    When I check IHS eligibility for patient "1"
    Then the eligibility determination should be undetermined
    And the raw eligibility status should be "I"
    And the patient should not be eligible for IHS services

  Scenario: An empty eligibility read is undetermined, never eligible
    Given the eligibility read for patient "1" returns nothing
    When I check IHS eligibility for patient "1"
    Then the eligibility determination should be undetermined
    And the patient should not be eligible for IHS services

  Scenario: A patient with no enrollment number is not eligible
    Given patient "4" has no enrollment number on file
    When I check IHS eligibility for patient "4"
    Then the eligibility determination should be undetermined
    And the patient should not be eligible for IHS services

  Scenario: A status determined eligible requires the signed-off mapping
    # PARKED on #520: asserting that any I/D/C/P code confers IHS eligibility
    # requires the compliance-signed-off mapping. A fabricated mapping would
    # violate the fail-closed non-negotiable, so this scenario skips rather
    # than passing by invention.
    When the signed-off eligibility mapping is required
    Then the patient can be determined eligible for IHS services

  Scenario: Service unit is a table lookup by IEN
    Given service unit 5 is named "Anchorage"
    When I look up service unit 5
    Then I should see service unit information:
      | name | Anchorage |

  Scenario: Tribe information comes from the enrollment's tribe pointer
    Given the enrollment read for patient "1" returns tribe pointer 100
    And tribe 100 is "Example Native Health (EXNH)" with code "EXNH"
    When I request tribe information for patient "1"
    Then I should see tribe details:
      | name | Example Native Health (EXNH) |
      | code | EXNH                         |

  Scenario: A patient whose enrollment names no tribe has no tribe information
    Given the enrollment read for patient "1" returns no tribe pointer
    When I request tribe information for patient "1"
    Then no tribe information should be available

  Scenario: Patient with missing enrollment number cannot be validated
    Given patient "4" has no enrollment number on file
    When I attempt to validate the patient's tribal enrollment
    Then I should see an error message "No enrollment number"
    And the validation should indicate invalid
