@onc
Feature: SMART EHR Launch
  As an ONC-certified EHR system
  The SMART EHR launch endpoint should follow the SMART App Launch Framework
  So that apps can be launched from within the EHR per 170.315(g)(10)(iii)

  ONC 170.315(g)(10)(iii) - Application registration and EHR launch

  Scenario: EHR launch without launch and iss returns 400
    When I request GET "/smart/launch" without authentication
    Then the response status should be 400
    And the response JSON should include error "invalid_request"

  Scenario: EHR launch with launch and iss but no client_id returns launch context JSON
    When I request GET "/smart/launch?launch=abc123&iss=http://example.com/fhir" without authentication
    Then the response status should be 200
    And the response JSON should include "launch"
    And the response JSON should include "authorization_endpoint"
    And the response JSON should include "token_endpoint"

  Scenario: EHR launch with launch, iss, and client_id redirects to authorize endpoint
    Given a SMART application is registered with client_id "test-app"
    When I request GET "/smart/launch?launch=abc123&iss=http://example.com/fhir&client_id=test-app" without authentication
    Then the response status should be 302
    And the response should redirect to the authorize endpoint
