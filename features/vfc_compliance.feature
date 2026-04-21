Feature: VFC compliance
  As an immunization program
  I need to enforce VFC eligibility before administering funded vaccines
  So that I comply with federal VFC program requirements

  Scenario: VFC-eligible patient receives VFC vaccine successfully
    Given patient "1" has VFC eligibility code "V04"
    When I check VFC eligibility for patient "1"
    Then the patient should be VFC eligible

  Scenario: Non-eligible patient blocked from VFC vaccine
    Given patient "99" has VFC eligibility code "V01"
    When I check VFC eligibility for patient "99"
    Then the patient should not be VFC eligible

  Scenario: Non-VFC lot available to any patient
    Given patient "99" has VFC eligibility code "V01"
    Then a non-VFC vaccine lot should be available regardless of eligibility

  Scenario: VFC eligibility codes are enumerable
    When I list all VFC eligibility codes
    Then the list should include code "V04" with label containing "AI/AN"
    And the list should include code "V01" with label containing "Not"

  Scenario: VFC eligible codes are V02 through V07
    Then code "V02" should be VFC eligible
    And code "V03" should be VFC eligible
    And code "V04" should be VFC eligible
    And code "V05" should be VFC eligible
    And code "V06" should be VFC eligible
    And code "V07" should be VFC eligible
    And code "V01" should not be VFC eligible
