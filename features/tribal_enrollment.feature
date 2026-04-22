Feature: Tribal Enrollment Management
  As a healthcare provider at an IHS facility
  I need to verify and manage patient tribal enrollment information
  So that I can determine eligibility for IHS services and CHS referrals

  Background:
    Given the following patients exist:
      | dfn | first_name | last_name | dob        | sex | ssn         | tribal_enrollment | tribal_affiliation                    | service_area |
      | 1   | Alice      | Anderson  | 1980-05-15 | F   | 111-11-1111 | ANLC-12345       | Alaska Native - Anchorage (ANLC)      | Anchorage    |
      | 2   | Bob        | Brown     | 1975-08-20 | M   | 222-22-2222 | CN-67890         | Cherokee Nation                        | Tahlequah    |
      | 3   | Charlie    | Chen      | 1990-03-10 | M   | 333-33-3333 | INVALID          | Unknown                                | Seattle      |
      | 4   | Diana      | Davis     | 1985-12-01 | F   | 444-44-4444 |                  |                                        | Portland     |

  Scenario: View patient tribal enrollment details
    When I request tribal enrollment details for patient "1"
    Then I should see tribal enrollment information:
      | enrollment_number | ANLC-12345                            |
      | tribe_name        | Alaska Native - Anchorage (ANLC)      |
      | status            | ACTIVE                                |
      | service_unit      | Anchorage                             |
      | tribe_code        | ANLC                                  |
    And the enrollment date should be present

  Scenario: Validate active tribal enrollment number
    When I validate tribal enrollment number "ANLC-12345"
    Then the enrollment should be valid
    And the tribe code should be "ANLC"
    And the status should be "ACTIVE"
    And I should see the message "Valid enrollment"

  Scenario: Validate invalid tribal enrollment number
    When I validate tribal enrollment number "INVALID"
    Then the enrollment should not be valid
    And the status should be "INACTIVE"
    And I should see the message "Enrollment not found or inactive"

  Scenario: Check patient eligibility for IHS services
    When I check IHS eligibility for patient "1"
    Then the patient should be eligible for IHS services
    And the eligibility should show:
      | active            | true      |
      | eligible_for_ihs  | true      |
      | service_unit      | Anchorage |
      | benefit_package   | BASIC     |

  Scenario: Check ineligible patient for IHS services
    When I check IHS eligibility for patient "4"
    Then the patient should not be eligible for IHS services
    And the eligibility should show:
      | active            | false |
      | eligible_for_ihs  | false |

  Scenario: Get patient service unit
    When I request the service unit for patient "1"
    Then I should see service unit information:
      | name   | Anchorage |
      | region | Alaska    |

  Scenario: Get tribe information by code
    When I request tribe information for "ANLC"
    Then I should see tribe details:
      | name          | Alaska Native - Anchorage (ANLC) |
      | code          | ANLC                             |
      | service_unit  | Anchorage                        |
      | region        | Alaska                           |
      | area          | Alaska Area                      |

  Scenario: Check if enrollment is valid using Patient model
    Given I have patient "1" with enrollment "ANLC-12345"
    When I check if the patient's tribal enrollment is valid
    Then the enrollment validation should return true

  Scenario: Verify patient eligibility using convenience method
    Given I have patient "1" with enrollment "ANLC-12345"
    When I check if the patient is eligible for IHS services
    Then the patient eligibility should return true

  Scenario: Multiple tribe information lookups
    When I request tribe information for the following codes:
      | tribe_code |
      | ANLC       |
      | CN         |
      | NN         |
      | OST        |
    Then I should receive tribe information for all codes
    And each tribe should have:
      | name          |
      | code          |
      | service_unit  |
      | region        |
      | area          |

  Scenario: Extract tribe code from enrollment number
    Given I have patient "1" with enrollment "ANLC-12345"
    When I request tribe information for the patient
    Then the tribe code should be extracted as "ANLC"
    And I should see the full tribe information

  Scenario: Patient with missing enrollment number
    Given I have patient "4" with no enrollment number
    When I attempt to validate the patient's tribal enrollment
    Then I should see an error message "No enrollment number"
    And the validation should indicate invalid

  Scenario: Service request eligibility depends on tribal enrollment
    Given I have patient "1" with enrollment "ANLC-12345"
    And I create a service request for specialty care
    When the eligibility service checks tribal enrollment
    Then the tribal enrollment check should pass
    And the service request should proceed to next eligibility step
