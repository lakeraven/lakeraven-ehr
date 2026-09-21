@part2 @pending
Feature: 42 CFR Part 2 outbound disclosure gate
  As a privacy officer at a clinic holding substance-use treatment records
  I need every path that sends a record out of the system to be consent-gated
  So that Part 2 content cannot leave without a consent naming recipient and purpose

  # Specification ahead of implementation (#497). Part 2 differs from HIPAA on
  # egress, not on storage: §2.31 requires a consent naming recipient and
  # purpose, §2.32 requires a redisclosure notice on every release, and §2.13(d)
  # requires that the patient be able to ask what left and where it went.
  #
  # Read-side segmentation is #494. The accounting ledger already exists
  # (features/onc/accounting_of_disclosures.feature); what is missing is the
  # gate in front of egress and the automatic write into that ledger.
  #
  # Steps are intentionally undefined rather than stubbed (#484).

  Background:
    Given the following patients exist:
      | dfn | first_name | last_name | dob        | sex |
      | 1   | Alice      | Anderson  | 1980-05-15 | F   |
    And patient "1" has a note flagged as Part 2 content
    And patient "1" has a note not flagged as Part 2 content

  # ---------------------------------------------------------------------------
  # The gate
  # ---------------------------------------------------------------------------

  Scenario: Outbound disclosure of Part 2 content is denied without consent
    Given patient "1" has no active Part 2 consent
    When an outbound referral is sent for patient "1" including the Part 2 note
    Then the disclosure should be denied
    And the referral should not be transmitted

  Scenario: Outbound disclosure is allowed when a consent covers recipient and purpose
    Given patient "1" has an active Part 2 consent for recipient "Example Behavioral Health" and purpose "treatment"
    When an outbound referral is sent to "Example Behavioral Health" for purpose "treatment" including the Part 2 note
    Then the disclosure should be allowed

  Scenario: A consent for a different recipient does not authorize this disclosure
    Given patient "1" has an active Part 2 consent for recipient "Example Behavioral Health" and purpose "treatment"
    When an outbound referral is sent to "Example Primary Care" for purpose "treatment" including the Part 2 note
    Then the disclosure should be denied

  Scenario: A consent for a different purpose does not authorize this disclosure
    Given patient "1" has an active Part 2 consent for recipient "Example Behavioral Health" and purpose "treatment"
    When an outbound referral is sent to "Example Behavioral Health" for purpose "payment" including the Part 2 note
    Then the disclosure should be denied

  Scenario: An expired consent does not authorize this disclosure
    Given patient "1" has a Part 2 consent that expired 1 day ago
    When an outbound referral is sent for patient "1" including the Part 2 note
    Then the disclosure should be denied

  Scenario: A revoked consent does not authorize this disclosure
    Given patient "1" has a Part 2 consent that was revoked
    When an outbound referral is sent for patient "1" including the Part 2 note
    Then the disclosure should be denied

  Scenario: Non-Part-2 content is unaffected by the gate
    Given patient "1" has no active Part 2 consent
    When an outbound referral is sent for patient "1" including only the non-Part-2 note
    Then the disclosure should be allowed

  # ---------------------------------------------------------------------------
  # Mixed payloads — silence is the failure mode
  # ---------------------------------------------------------------------------

  Scenario: A mixed payload is never silently trimmed
    Given patient "1" has no active Part 2 consent
    When an outbound referral is sent for patient "1" including both notes
    Then the disclosure should be denied
    And the response should state that Part 2 content was withheld
    And the recipient should not receive a payload that appears complete

  Scenario: An explicitly redacted payload declares its redaction
    Given patient "1" has no active Part 2 consent
    And the caller requests redaction rather than refusal
    When an outbound referral is sent for patient "1" including both notes
    Then the transmitted payload should contain the non-Part-2 note
    And the transmitted payload should declare that content was withheld under 42 CFR Part 2

  # ---------------------------------------------------------------------------
  # Every egress path, not just the one we remembered
  # ---------------------------------------------------------------------------

  Scenario Outline: Each egress path enforces the gate
    Given patient "1" has no active Part 2 consent
    When Part 2 content for patient "1" leaves through "<path>"
    Then the disclosure should be denied

    Examples:
      | path                 |
      | outbound referral    |
      | FHIR bundle export   |
      | EHI export           |
      | patient letter       |
      | in-basket forward    |
      | portal download      |

  Scenario: A response-rendering path outside the reviewed allowlist fails the convention check
    When the egress convention check runs
    Then every response-rendering path should be either gated or on the reviewed allowlist
    And a path in neither should fail the check

  # ---------------------------------------------------------------------------
  # Accounting and notice
  # ---------------------------------------------------------------------------

  Scenario: An allowed disclosure is written to the accounting ledger
    Given patient "1" has an active Part 2 consent for recipient "Example Behavioral Health" and purpose "treatment"
    When an outbound referral is sent to "Example Behavioral Health" for purpose "treatment" including the Part 2 note
    Then a disclosure record should exist for patient "1" with recipient "Example Behavioral Health"
    And the disclosure record should reference the consent that authorized it
    And the disclosure record should list which records were disclosed

  Scenario: An allowed disclosure carries the redisclosure prohibition notice
    Given patient "1" has an active Part 2 consent for recipient "Example Behavioral Health" and purpose "treatment"
    When an outbound referral is sent to "Example Behavioral Health" for purpose "treatment" including the Part 2 note
    Then the transmitted payload should carry the 42 CFR § 2.32 redisclosure notice

  Scenario: A denied disclosure is auditable
    Given patient "1" has no active Part 2 consent
    When an outbound referral is sent for patient "1" including the Part 2 note
    Then an audit event should record the denied disclosure

  Scenario: "Determined no Part 2 content" is distinguishable from "could not determine"
    Given the Part 2 flag for a note on patient "1" cannot be evaluated
    When an outbound referral is sent for patient "1" including that note
    Then the disclosure should be denied
    And the audit event should record an indeterminate Part 2 evaluation
    And the audit event should not record that no Part 2 content was present

  Scenario: Part 2 disclosures appear in the patient's accounting of disclosures
    Given patient "1" has an active Part 2 consent for recipient "Example Behavioral Health" and purpose "treatment"
    And an outbound referral including the Part 2 note has been sent to "Example Behavioral Health"
    When patient "1" requests their accounting of disclosures
    Then the report should include the disclosure to "Example Behavioral Health"
