@onc
Feature: Backend Services JWT Authentication
  As an ONC-certified EHR system
  The token endpoint should support backend services authorization with JWT client assertion
  So that system-to-system access is available per 170.315(g)(10)(vi)

  ONC 170.315(g)(10)(vi) - Patient authorization revocation

  Scenario: POST /oauth/token with client_credentials and client_assertion returns access_token
    Given a SMART backend service application is registered
    When I POST to "/oauth/token" with a valid client_credentials JWT assertion
    Then the response status should be 200
    And the response JSON should include "access_token"
    And the response JSON should include "token_type"

  Scenario: POST /oauth/token with client_credentials but missing client_assertion returns 400
    When I POST to "/oauth/token" with client_credentials but no client_assertion
    Then the response status should be 400
    And the response JSON should include error "invalid_client"

  Scenario: POST /oauth/token with invalid JWT returns 401
    When I POST to "/oauth/token" with an invalid JWT assertion
    Then the response status should be 401
    And the response JSON should include error "invalid_client"
