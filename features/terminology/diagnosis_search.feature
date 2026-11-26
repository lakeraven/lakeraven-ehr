@diagnosis_search
Feature: Find a diagnosis by its clinical term
  As a provider adding a new diagnosis for a patient
  I want to search RPMS's SNOMED CT by the term I know
  So that the problem and the visit carry the concept and ICD-10-CM code RPMS maps it to

  # rpms-ux S-VIS-02.4, the search before S-VIS-02.2 and S-VIS-02.3: VueCentric's
  # problem entry searches RPMS's terminology package (IHS Standard Terminology,
  # BSTS) before a new diagnosis is added. Each scenario here proves one part of
  # S-VIS-02.4's Then. RPMS answers from its own SNOMED CT copy; the concepts
  # named here ship with the pinned build.

  @live
  Scenario: A search finds the SNOMED CT concept and its ICD-10-CM code (rpms-ux S-VIS-02.4)
    Given the provider is signed in
    When the provider searches for the diagnosis "major depress"
    Then RPMS offers the SNOMED CT concept "370143000" with ICD-10-CM "F32.9"
    And the page offers words that start with "depress"
    When the provider opens the SNOMED CT concept "370143000"
    Then the concept's fully specified name is "Major depressive disorder (disorder)"
    And the concept's ICD-10-CM code is "F32.9"

  @live
  Scenario: A term RPMS holds no concept for says so (rpms-ux S-VIS-02.4)
    Given the provider is signed in
    When the provider searches for the diagnosis "zzqxv"
    Then the page says no SNOMED CT concept in RPMS matches "zzqxv"
    And no concept is offered

  @live
  Scenario: A user RPMS does not let search its terminology is told so, not shown an empty list (rpms-ux S-VIS-02.4)
    Given the front desk clerk is signed on to RPMS
    And the provider is signed in
    When the provider searches for the diagnosis "major depress"
    Then the page says RPMS refused the request
    And no concept is offered

  @app
  Scenario: Text the search cannot carry is refused before RPMS is asked
    Given the provider is signed in
    When the provider searches for the diagnosis "a|b"
    Then the page asks for a term without | or ^
