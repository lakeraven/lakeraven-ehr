@orhc_platform
Feature: ORHC booth demo platform behaviour (engine)
  ORHC Booth Demo Spec v1.1 §5 — meta.security HTEST (no per-resource meta.tag)
  and X-Request-Id on FHIR responses through the engine HTTP surface.

  Background:
    Given the ORHC platform test patient is seeded
    And I hold an org-bound SMART token for site 5001

  Scenario: Inbound X-Request-Id is echoed on a Patient read
    When I GET "/lakeraven-ehr/Patient/9101" with X-Request-Id "orhc-cucumber-echo-001"
    Then the response status should be 200
    And the response should echo X-Request-Id "orhc-cucumber-echo-001"

  Scenario: A generated X-Request-Id is returned when the client sends none
    When I GET "/lakeraven-ehr/Patient/9101"
    Then the response status should be 200
    And the response should include a generated X-Request-Id

  Scenario: HTEST security meta is present on a Patient read
    When I GET "/lakeraven-ehr/Patient/9101"
    Then the response status should be 200
    And the Patient resource should carry HTEST security meta
