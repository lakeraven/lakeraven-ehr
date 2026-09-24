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

  Scenario: POST /oauth/token with a forged JWT signature returns 401
    Given a SMART backend service application is registered
    When I POST to "/oauth/token" with a forged-signature client_credentials JWT assertion
    Then the response status should be 401
    And the response JSON should include error "invalid_client"

  Scenario: POST /oauth/token does not grant a scope the application is not registered for
    Given a SMART backend service application is registered
    When I POST to "/oauth/token" with a client_credentials JWT assertion requesting scope "system/*.write"
    Then the issued access token scopes should not include "system/*.write"

  Scenario: an issued token cannot export beyond the application's registered scopes
    Given a SMART backend service application is registered
    When I POST to "/oauth/token" with a client_credentials JWT assertion requesting scope "system/*.read system/*.write"
    And I POST to "/lakeraven-ehr/exports" with the issued access token
    Then the response status should be 403
