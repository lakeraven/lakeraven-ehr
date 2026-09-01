Feature: Record a purpose of visit on an open encounter
  As a clinical provider
  I need to record the purpose of visit (POV) against the patient's open visit
  So that the encounter documents why the patient was seen and can be closed

  Background:
    Given a patient with DFN 8791
    And a demo visit with IEN 2090061

  Scenario: Provider records a POV with diagnosis and narrative
    When the provider records POV "J06.9" with narrative "Acute upper respiratory infection"
    Then the POV save should succeed
    And the POV gateway should receive diagnosis "J06.9" for visit 2090061

  Scenario: Provider cannot record a POV without a diagnosis code
    When the provider records POV "" with narrative "Follow-up"
    Then the POV save should fail with :missing_diagnosis

  Scenario: Provider cannot record a POV without an open visit
    Given no open visit
    When the provider records POV "J06.9" with narrative "Acute upper respiratory infection"
    Then the POV save should fail with :invalid_input

  Scenario: Gateway failure surfaces as an error, never a silent success
    Given the POV gateway will fail
    When the provider records POV "J06.9" with narrative "Acute upper respiratory infection"
    Then the POV save should fail with :gateway_error
