Feature: Patient Search and Lookup
  As a healthcare provider
  I need to search and retrieve patient information from RPMS
  So that I can provide appropriate care and create referrals

  Background:
    Given the following patients are seeded:
      | dfn | name            | ssn         | dob        | sex | service_area |
      | 1   | Anderson,Alice  | 111-11-1111 | 1980-05-15 | F   | Anchorage    |
      | 2   | MOUSE,MICKEY M  | 000009999   | 2010-02-14 | M   | Arizona      |
      | 3   | DOE,JANE        | 555667777   | 1990-12-25 | F   | Oklahoma     |

  Scenario: Search for patient by name
    When I search for patients with name "Anderson"
    Then I should find 1 patient in the results
    And the patient results should include "Anderson,Alice"

  Scenario: Search for patient by SSN
    When I search for patients with SSN "111-11-1111"
    Then I should find 1 patient in the results
    And the patient should have name "Anderson,Alice"

  Scenario: Retrieve patient by DFN
    When I retrieve patient with DFN 1
    Then I should see patient "Anderson,Alice"
    And the patient demographics should show:
      | Field         | Value       |
      | Date of Birth | 05/15/1980  |
      | Sex           | Female      |
      | SSN           | 111-11-1111 |
      | Service Area  | Anchorage   |

  Scenario: View patient with referrals
    Given patient 1 has referrals seeded
    When I retrieve patient with DFN 1
    And I view the patient's referrals
    Then I should see at least 1 referral

  Scenario: Search with no results
    When I search for patients with name "Nonexistent"
    Then I should find 0 patients in the results

  Scenario: Retrieve nonexistent patient
    When I retrieve patient with DFN 99999
    Then the patient should be nil

  Scenario: Search returns multiple patients
    When I search for patients with name ""
    Then I should find 3 patients in the results
