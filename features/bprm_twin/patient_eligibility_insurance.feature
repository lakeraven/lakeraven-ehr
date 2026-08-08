# BPRM twin — scenario #3: Patient eligibility + third-party insurance
# HTTP:  GET  /patients/:dfn/insurances
#        PATCH  /patients/:dfn/insurances/:id
#        DELETE /patients/:dfn/insurances/:id
# RPC:   read via BMX query; write via AG insurance API -> ^DIE on ^AUPNPAT / insurance files
# BPRM:  BsdGetPatientInsurances, AgGetPatientInsuranceInUse (read);
#        AgSetPatientInsuranceDelete (dynamic-SQL 7-table cascade DELETE)
# Disposition: read + sql-mutate -> reimpl  (the 7-table delete is the highest-risk audit-gap item)
@bprm_twin @registration @eligibility
Feature: Patient eligibility and third-party insurance
  As a benefits coordinator
  I want to view and maintain a patient's insurance coverage
  So that visits bill to the correct third-party payer

  Background:
    Given a registered patient with DFN 42
    And patient 42 has the following insurances:
      | id | payer              | policy_no   | type      | in_use |
      | 1  | Medicaid (WA)      | WA55501234  | Medicaid  | yes    |
      | 2  | Contract Health    | CHS-2026-88 | Tribal    | yes    |

  Scenario: List a patient's insurances
    When I request the insurances for patient 42
    Then I see 2 insurances
    And insurance "Medicaid (WA)" is flagged in-use

  Scenario: Update a policy number
    When I update insurance 1 for patient 42 with policy number "WA55509999"
    Then the update succeeds
    And insurance 1 now has policy number "WA55509999"

  Scenario: Delete an insurance and cascade its dependent records safely
    When I delete insurance 2 for patient 42
    Then the delete succeeds
    And patient 42 has 1 insurance remaining
    And all dependent coverage records for insurance 2 are removed through FileMan
    And no orphaned cross-reference remains for insurance 2

  Scenario: Deleting an in-use insurance is blocked
    When I delete insurance 1 for patient 42
    Then the delete is rejected with status 409
    And the error message mentions "in use"
