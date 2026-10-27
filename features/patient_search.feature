Feature: Patient Search and Lookup
  As a healthcare provider
  I need to search and retrieve patient information from RPMS
  So that I can provide appropriate care and create referrals

# The demo patients of the pinned RPMS build (rpms-ops demo site seed), as
# RPMS returns them. The mock is seeded from this table, and a live run
# (cucumber --profile live) fails if RPMS disagrees with any row.
Background:
  Given these RPMS demo patients:
    | dfn    | name         | ssn       | dob        | sex |
    | 990051 | ALPHA,AVERY  | 666521051 | 1954-05-14 | F   |
    | 990001 | ALPHA,CASEY  | 666021001 | 1952-05-26 | F   |
    | 990027 | ANCHOR,JAMIE | 666281027 | 1962-06-11 | F   |

  Scenario: Search for patient by name
    When I search for patients with name "ANCHOR"
    Then I should find 1 patient in the results
    And the patient results should include "ANCHOR,JAMIE"

  Scenario: Search for patient by SSN
    When I search for patients with SSN "666-28-1027"
    Then I should find 1 patient in the results
    And the patient should have name "ANCHOR,JAMIE"

  # DEFERRED (@unsourced): the read this needs lives in rpms-rpc, not the
    # engine, and the field numbers were only verified against the live DD on
    # 2026-10-01. Asserts city/address, same #2 address fields as above.
    # Tracked: lakeraven-ehr#564 and rpms-rpc#294.
  @unsourced
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
    Given patient 990001 has referrals seeded
    When I retrieve patient with DFN 990001
    And I view the patient's referrals
    Then I should see at least 1 referral

  Scenario: Search with no results
    When I search for patients with name "Nonexistent"
    Then I should find 0 patients in the results

  Scenario: Retrieve nonexistent patient
    When I retrieve patient with DFN 99999
    Then the patient should be nil

  Scenario: Search returns multiple patients
    When I search for patients with name "ALPHA"
    Then I should find 2 patients in the results
