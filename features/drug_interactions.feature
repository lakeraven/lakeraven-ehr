Feature: Drug Interaction Checking (ONC § 170.315(a)(4))
  As a healthcare provider
  I need to check for drug-drug and drug-allergy interactions before prescribing
  So that I can prevent adverse drug events and comply with ONC certification

  Background:
    Given the following patients exist:
      | dfn | first_name | last_name | dob        | sex |
      | 1   | Alice      | Anderson  | 1980-05-15 | F   |
      | 2   | Bob        | Brown     | 1975-08-20 | M   |

  Scenario: Detect high-severity drug-drug interaction
    Given patient "1" has the following active medications:
      | drug_name | rxnorm_code |
      | warfarin  | 11289       |
    When I check drug interactions for prescribing "aspirin" with RxNorm "1191" to patient "1"
    Then the interaction check should not be safe
    And the interaction check should be blocking
    And I should see a drug-drug interaction between "warfarin" and "aspirin" with severity "high"

  Scenario: Detect moderate-severity interaction (warn, don't block)
    Given patient "1" has the following active medications:
      | drug_name  | rxnorm_code |
      | lisinopril | 29046       |
    When I check drug interactions for prescribing "potassium chloride" with RxNorm "8591" to patient "1"
    Then the interaction check should not be safe
    And the interaction check should not be blocking
    And I should see a drug-drug interaction between "lisinopril" and "potassium chloride" with severity "moderate"

  Scenario: No interactions — safe to prescribe
    Given patient "1" has the following active medications:
      | drug_name     | rxnorm_code |
      | acetaminophen | 161         |
    When I check drug interactions for prescribing "amoxicillin" with RxNorm "723" to patient "1"
    Then the interaction check should be safe
    And the interaction check should not be blocking
    And there should be no interactions detected

  Scenario: Drug-allergy interaction detected
    Given patient "1" has the following active medications:
      | drug_name     | rxnorm_code |
      | acetaminophen | 161         |
    And patient "1" has the following allergies:
      | allergen   | allergen_code | category   |
      | penicillin | 7980          | medication |
    When I check drug interactions for prescribing "amoxicillin" with RxNorm "723" to patient "1"
    Then the interaction check should not be safe
    And I should see a drug-allergy interaction for "amoxicillin"

  Scenario: Cross-reactivity alert (penicillin to cephalosporin)
    Given patient "1" has the following active medications:
      | drug_name     | rxnorm_code |
      | acetaminophen | 161         |
    And patient "1" has the following allergies:
      | allergen   | allergen_code | category   |
      | penicillin | 7980          | medication |
    When I check drug interactions for prescribing "cephalexin" with RxNorm "2231" to patient "1"
    Then the interaction check should not be safe
    And I should see a drug-allergy interaction for "cephalexin"
    And the interaction description should mention "cross-reactivity"

  Scenario: Patient with no active medications
    Given patient "2" has no active medications
    When I check drug interactions for prescribing "lisinopril" with RxNorm "29046" to patient "2"
    Then the interaction check should be safe
    And there should be no interactions detected

  Scenario: Patient with no known allergies
    Given patient "1" has the following active medications:
      | drug_name | rxnorm_code |
      | warfarin  | 11289       |
    And patient "1" has no known allergies
    When I check drug interactions for prescribing "acetaminophen" with RxNorm "161" to patient "1"
    Then the interaction check should be safe

  Scenario: Multiple interactions for one proposed medication
    Given patient "1" has the following active medications:
      | drug_name  | rxnorm_code |
      | warfarin   | 11289       |
      | fluoxetine | 4493        |
    When I check drug interactions for prescribing "ibuprofen" with RxNorm "5640" to patient "1"
    Then the interaction check should not be safe
    And there should be at least 2 interactions detected

  Scenario: Batch check multiple proposed medications
    Given patient "1" has the following active medications:
      | drug_name | rxnorm_code |
      | warfarin  | 11289       |
    When I batch check the following medications for patient "1":
      | drug_name     | rxnorm_code |
      | aspirin       | 1191        |
      | acetaminophen | 161         |
    Then "aspirin" should have interactions detected
    And "acetaminophen" should have no interactions detected

  Scenario: Unknown drug handled gracefully
    Given patient "1" has the following active medications:
      | drug_name | rxnorm_code |
      | warfarin  | 11289       |
    When I check drug interactions for prescribing "unknowndrug" with RxNorm "999999" to patient "1"
    Then the interaction check should be safe

  Scenario: FHIR DetectedIssue generated for each interaction
    Given patient "1" has the following active medications:
      | drug_name | rxnorm_code |
      | warfarin  | 11289       |
    When I check drug interactions for prescribing "aspirin" with RxNorm "1191" to patient "1"
    Then the result should include FHIR DetectedIssue resources
    And each DetectedIssue should have a valid resourceType
    And each DetectedIssue should have a severity
    And each DetectedIssue should have implicated items

  Scenario: Adapter failure handled gracefully
    Given the drug interaction adapter is unavailable
    When I check drug interactions for prescribing "aspirin" with RxNorm "1191" to patient "1"
    Then the interaction check should indicate an error
    And the error message should mention "error"

  Scenario: RPMS mode should produce non-degraded decision metadata
    Given the interaction adapter mode is "rpms"
    And patient "1" has the following active medications:
      | drug_name | rxnorm_code |
      | warfarin  | 11289       |
    When I check drug interactions for prescribing "aspirin" with RxNorm "1191" to patient "1"
    Then the interaction check should not indicate an error
    And the decision source should be "rpms"
    And the interaction check should not be degraded

  Scenario: RPMS mode should return RPMS-sourced interaction alerts
    Given the interaction adapter mode is "rpms"
    And the RPMS order check returns a critical drug-drug interaction
    And patient "1" has the following active medications:
      | drug_name | rxnorm_code |
      | warfarin  | 11289       |
    When I check drug interactions for prescribing "aspirin" with RxNorm "1191" to patient "1"
    Then I should see a drug-drug interaction between "warfarin" and "aspirin" with severity "high"
    And the interaction source should be "RPMS"
