Feature: SMART EHR launch
  As a SMART-on-FHIR client launched from an EHR
  I need the EHR to bind a patient context to my launch
  So that I receive the patient identifier in my access token without
  prompting the user to pick a patient again

  Background:
    Given the EHR adapter is the in-memory mock
    And the current tenant is "tnt_test"
    And the current facility is "fac_main"
    And the following patients are registered at facility "fac_main":
      | display_name | date_of_birth | gender |
      | DOE,JOHN     | 1980-01-15    | male   |
    And a confidential OAuth client is registered with scopes "system/Patient.read launch/patient"

  Scenario: Host application mints a launch context bound to a patient
    Given the host mints a launch context for patient "DOE,JOHN"
    Then the launch context has a launch_token starting with "lc_"
    And the launch context binds the tenant "tnt_test"

  Scenario: Token request with a valid launch token returns the patient context
    Given the host mints a launch context for patient "DOE,JOHN"
    When I POST to the OAuth token endpoint with grant_type "client_credentials" and the launch token
    Then the response status is 200
    And the response body includes an access_token
    And the response body patient field equals the bound patient_identifier

  Scenario: Token request without launch returns no patient context
    When I POST to the OAuth token endpoint with grant_type "client_credentials" and the client credentials
    Then the response status is 200
    And the response body has no patient field

  Scenario: Token request with an unknown launch token still issues a token but no patient
    When I POST to the OAuth token endpoint with grant_type "client_credentials" and an unknown launch token
    Then the response status is 200
    And the response body has no patient field

  Scenario: Token request with an expired launch token still issues a token but no patient
    Given the host mints a launch context for patient "DOE,JOHN" that expires in 1 minute
    And 5 minutes pass
    When I POST to the OAuth token endpoint with grant_type "client_credentials" and the launch token
    Then the response status is 200
    And the response body has no patient field
