@onc
Feature: Patient Record Amendments (ONC § 170.315(d)(4))
  As a patient or provider
  I need to request and process amendments to health records
  So that patient data is accurate per HIPAA Right of Amendment

  Background:
    Given the following patients exist:
      | dfn | first_name | last_name | dob        | sex |
      | 1   | Alice      | Anderson  | 1980-05-15 | F   |

  # ---------------------------------------------------------------------------
  # Amendment request creation
  # ---------------------------------------------------------------------------

  Scenario: Patient requests an amendment to their health record
    When patient "1" requests an amendment with:
      | field        | value                                       |
      | resource     | AllergyIntolerance                          |
      | description  | Penicillin allergy should be Amoxicillin    |
      | reason       | Original entry was incorrect medication name |
    Then the amendment request should be created with status "pending"
    And the amendment should have an audit trail entry

  Scenario: Amendment request requires description and reason
    When patient "1" requests an amendment with:
      | field        | value              |
      | resource     | AllergyIntolerance |
      | description  |                    |
      | reason       |                    |
    Then the amendment request should be invalid

  # ---------------------------------------------------------------------------
  # Provider accepts amendment
  # ---------------------------------------------------------------------------

  Scenario: Provider accepts an amendment request
    Given patient "1" has a pending amendment request
    When provider "789" accepts the amendment with reason "Verified correct medication name"
    Then the amendment status should be "accepted"
    And the amendment should record the reviewer as "789"
    And the amendment should have an audit trail entry for "accepted"

  # ---------------------------------------------------------------------------
  # Provider denies amendment
  # ---------------------------------------------------------------------------

  Scenario: Provider denies an amendment request with reason
    Given patient "1" has a pending amendment request
    When provider "789" denies the amendment with reason "Record is clinically accurate as documented"
    Then the amendment status should be "denied"
    And the amendment should record the denial reason
    And the amendment should have an audit trail entry for "denied"

  Scenario: Denied amendment reason is required
    Given patient "1" has a pending amendment request
    When provider "789" denies the amendment without a reason
    Then the denial should fail with a validation error

  # ---------------------------------------------------------------------------
  # Amendment history
  # ---------------------------------------------------------------------------

  Scenario: Amendment history is preserved for a patient
    Given patient "1" has the following amendment history:
      | status   | resource             | description                    |
      | accepted | AllergyIntolerance   | Changed penicillin to amox     |
      | denied   | Condition            | Remove diabetes diagnosis      |
      | pending  | Observation          | Correct blood pressure reading |
    When I retrieve amendment history for patient "1"
    Then the history should contain 3 amendments
    And the history should include both accepted and denied amendments

  Scenario: Denied amendment is appended to record per HIPAA
    Given patient "1" has a pending amendment request for "Condition"
    When provider "789" denies the amendment with reason "Clinically accurate"
    Then the denied amendment should be preserved in the patient's amendment history
    And the original record should remain unchanged

  # ---------------------------------------------------------------------------
  # Performance
  # ---------------------------------------------------------------------------

  Scenario: Amendment operations complete within acceptable time
    When patient "1" requests an amendment with timing
    Then the amendment creation should complete within 2 seconds
