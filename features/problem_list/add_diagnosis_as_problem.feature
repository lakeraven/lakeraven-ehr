@problem_entry
Feature: Add the diagnosis a provider found as a problem, and as today's purpose of visit
  As a provider with a new diagnosis for the patient in front of me
  I want to add the concept I found as a problem, and choose whether it is today's purpose of visit
  So that the problem list and the visit both carry it, coded as RPMS codes it

  # rpms-ux S-VIS-02.2 and S-VIS-02.3. RPMS files them as VueCentric's problem
  # entry does: BGOPROB2 DUPCHK, then BGOPROB SET with the SNOMED CT concept
  # and the ICD-10-CM code BSTS maps, then BGOVPOV SET against the new problem.
  # The page shows what RPMS read back.
  #
  # These scenarios write. They run only against a disposable RPMS on this
  # machine, on patients this feature owns (990022 with a visit today, 990026
  # with none), and remove what they filed.

  @live
  Scenario: The provider adds the diagnosis as a problem and today's purpose of visit (rpms-ux S-VIS-02.2) (whole Then)
    Given patient "990022", whom this feature owns, has an open visit today
    And the provider has signed on as "PMD123" and opened the record of patient "990022"
    When the provider finds "major depress" and opens the SNOMED CT concept "370143000"
    And the provider chooses "Add as a problem"
    Then the page offers today's open visit with "Today's purpose of visit" ticked
    When the provider saves
    Then the page shows the problem RPMS stored, SNOMED CT "370143000" with ICD-10-CM "F32.9"
    And the page shows the purpose of visit RPMS stored on today's visit, ICD-10-CM "F32.9"
    And RPMS's problem list for the patient holds SNOMED CT "370143000" once
    And RPMS holds the purpose of visit on today's visit, filed against that problem
    And the patient's chart lists the problem "Major depressive disorder"

  @live
  Scenario: With the box cleared only the problem is added (rpms-ux S-VIS-02.3) (whole Then)
    Given patient "990022", whom this feature owns, has an open visit today
    And the provider has signed on as "PMD123" and opened the record of patient "990022"
    When the provider finds "generalized anxiety" and opens the SNOMED CT concept "21897009"
    And the provider chooses "Add as a problem"
    And the provider clears "Today's purpose of visit" and saves
    Then the page shows the problem RPMS stored, SNOMED CT "21897009" with ICD-10-CM "F41.1"
    And RPMS's problem list for the patient holds SNOMED CT "21897009" once
    And RPMS holds no purpose of visit on today's visit for that problem

  @live
  Scenario: A concept BSTS maps to two ICD-10-CM codes carries both (rpms-ux S-VIS-02.2) (whole Then)
    Given patient "990022", whom this feature owns, has an open visit today
    And the provider has signed on as "PMD123" and opened the record of patient "990022"
    When the provider finds "diabetic nephropathy" and opens the SNOMED CT concept "421986006"
    And the provider chooses "Add as a problem"
    And the provider saves
    Then the page shows the problem RPMS stored, SNOMED CT "421986006" with ICD-10-CM "E11.29, R80.1"
    And RPMS holds the purpose of visit on today's visit, filed against that problem, with ICD-10-CM "E11.29, R80.1"

  @live
  Scenario: A concept that asks for the side asks for it before saving
    Given patient "990022", whom this feature owns, has an open visit today
    And the provider has signed on as "PMD123" and opened the record of patient "990022"
    When the provider finds "otitis media" and opens the SNOMED CT concept "65363002"
    And the provider chooses "Add as a problem"
    Then the page asks for the side: "Left", "Right" or "Bilateral"
    When the provider clears "Today's purpose of visit" and saves
    Then the page says "Choose the side: Left, Right, Bilateral." and nothing was saved
    When the provider chooses the side "Left", clears "Today's purpose of visit" and saves
    Then the page shows the problem RPMS stored, SNOMED CT "65363002" with ICD-10-CM "H66.90"
    And the page shows the side "Left"

  @live
  Scenario: A concept on the list already is said so, and RPMS's answer saves nothing
    Given patient "990022", whom this feature owns, has an open visit today
    And the patient's problem list holds SNOMED CT "370143000", filed through RPMS
    And the provider has signed on as "PMD123" and opened the record of patient "990022"
    When the provider finds "major depress" and opens the SNOMED CT concept "370143000"
    And the provider chooses "Add as a problem"
    Then the page says the concept is on the patient's problem list already, and offers no save
    When the provider sends the form anyway
    Then the page says "This concept is on the patient's problem list already. Nothing was saved." with status 409
    And RPMS's problem list for the patient holds SNOMED CT "370143000" once

  @live
  Scenario: With no open visit today it can be a problem only, and asking for the purpose of visit saves nothing
    Given patient "990026", whom this feature owns, has no open visit today
    And the provider has signed on as "PMD123" and opened the record of patient "990026"
    When the provider finds "major depress" and opens the SNOMED CT concept "370143000"
    And the provider chooses "Add as a problem"
    Then the page says the patient has no open visit today, and offers no purpose of visit
    When the provider sends the form anyway, as today's purpose of visit
    Then the page says "The patient has no open visit today, so it cannot be today's purpose of visit. Nothing was saved." with status 422
    And RPMS's problem list for the patient does not hold SNOMED CT "370143000"

  @live
  Scenario: A user whose RPMS keys do not let them chart is refused, and nothing is saved
    Given patient "990022", whom this feature owns, has an open visit today
    And the front desk clerk has signed on as "PREG123" and opened the record of patient "990022"
    When the front desk clerk sends the form to add the SNOMED CT concept "370143000"
    Then the page says the account does not hold the security key, with status 403
    And RPMS's problem list for the patient does not hold SNOMED CT "370143000"
