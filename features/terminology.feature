# frozen_string_literal: true

Feature: Terminology serializers
  As a healthcare system
  I need to serialize clinical codes into standard terminology systems
  So that coded data is interoperable across markets

  # --- ICD-10 ---

  Scenario: ICD-10-CM code (US edition)
    Given an ICD-10 code "E11.9" with edition "cm"
    Then the terminology system should be "http://hl7.org/fhir/sid/icd-10-cm"
    And the terminology code should be "E11.9"
    And the terminology status should be "mapped"

  Scenario: ICD-10-SE code (Swedish edition)
    Given an ICD-10 code "E11.9" with edition "se"
    Then the terminology system should be "http://hl7.org/fhir/sid/icd-10-se"

  Scenario: ICD-10-CA code (Canadian edition)
    Given an ICD-10 code "E11.9" with edition "ca"
    Then the terminology system should be "http://hl7.org/fhir/sid/icd-10-ca"

  Scenario: ICD-10 international (no edition)
    Given an ICD-10 code "E11.9" with no edition
    Then the terminology system should be "http://hl7.org/fhir/sid/icd-10"

  Scenario: ICD-10 to FHIR Coding
    Given an ICD-10 code "E11.9" with edition "cm"
    When I convert to FHIR Coding
    Then the coding system should be "http://hl7.org/fhir/sid/icd-10-cm"
    And the coding code should be "E11.9"

  Scenario: Empty ICD-10 code is unmapped
    Given an ICD-10 code "" with edition "cm"
    Then the terminology status should be "unmapped"

  # --- LOINC ---

  Scenario: LOINC observation code
    Given a LOINC code "8867-4"
    Then the terminology system should be "http://loinc.org"
    And the terminology code should be "8867-4"
    And the terminology status should be "mapped"

  Scenario: LOINC to FHIR Coding
    Given a LOINC code "8867-4"
    When I convert to FHIR Coding
    Then the coding system should be "http://loinc.org"
    And the coding code should be "8867-4"

  # --- RxNorm ---

  Scenario: RxNorm medication code
    Given an RxNorm code "860975"
    Then the terminology system should be "http://www.nlm.nih.gov/research/umls/rxnorm"
    And the terminology code should be "860975"

  Scenario: RxNorm to FHIR Coding
    Given an RxNorm code "860975"
    When I convert to FHIR Coding
    Then the coding system should be "http://www.nlm.nih.gov/research/umls/rxnorm"

  # --- ATC (WHO) ---

  Scenario: ATC drug classification code
    Given an ATC code "A10BA02"
    Then the terminology system should be "http://www.whocc.no/atc"
    And the terminology code should be "A10BA02"

  # --- DIN (Health Canada) ---

  Scenario: DIN drug identification code
    Given a DIN code "02248573"
    Then the terminology system should be "https://health-products.canada.ca/dpd-bdpp"
    And the terminology code should be "02248573"

  # --- SNOMED CT ---

  Scenario: SNOMED CT code (no edition)
    Given a SNOMED code "73211009" with no edition
    Then the terminology system should be "http://snomed.info/sct"
    And the terminology code should be "73211009"

  Scenario: SNOMED CT US edition
    Given a SNOMED code "73211009" with edition "us"
    When I convert to FHIR Coding
    Then the coding version should be "http://snomed.info/sct/731000124108"

  Scenario: SNOMED CT Swedish edition
    Given a SNOMED code "73211009" with edition "se"
    When I convert to FHIR Coding
    Then the coding version should be "http://snomed.info/sct/45991000052106"

  Scenario: SNOMED CT Canadian edition
    Given a SNOMED code "73211009" with edition "ca"
    When I convert to FHIR Coding
    Then the coding version should be "http://snomed.info/sct/20611000087101"

  Scenario: SNOMED CT international (no version)
    Given a SNOMED code "73211009" with no edition
    When I convert to FHIR Coding
    Then the coding should not have a version

  Scenario: Empty SNOMED code is unmapped
    Given a SNOMED code "" with no edition
    Then the terminology status should be "unmapped"

  Scenario: Whitespace-only code is unmapped
    Given an ICD-10 code "   " with edition "cm"
    Then the terminology status should be "unmapped"
