Feature: Encryption Verification
  As a HIPAA-compliant system
  Encryption at rest should be verifiable
  So that audit evidence can be produced per 45 CFR 164.312(a)(2)(iv)

  Scenario: Encryption verification reports application-observable status
    When I run the encryption verification
    Then the report should include "Application-Observable Encryption Status"
    And the report should include the database SSL status
    And the report should include ActiveRecord encryption status
    And the report should list encrypted columns

  Scenario: Report indicates infrastructure attestation required
    When I run the encryption verification
    Then the report should include "Infrastructure Attestation Required"
    And the report should indicate storage encryption requires external verification
