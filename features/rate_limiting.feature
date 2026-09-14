@security @pending
Feature: Rate limiting on API and public endpoints
  As an operator of a clinic system reachable from the public internet
  I need authentication, token redemption, and search endpoints to be throttled
  So that an attacker cannot enumerate tokens, stuff credentials, or scrape the panel

  # Specification ahead of implementation (#498). The engine has no rate
  # limiting today. #471 introduces an unauthenticated public tokenized-link
  # surface; #401 makes the login form a real credential target for the first
  # time. Steps are intentionally undefined rather than stubbed (#484).

  Background:
    Given the following patients exist:
      | dfn | first_name | last_name | dob        | sex |
      | 1   | Alice      | Anderson  | 1980-05-15 | F   |

  # ---------------------------------------------------------------------------
  # Authentication
  # ---------------------------------------------------------------------------

  Scenario: Repeated failed sign-ins are throttled
    When I submit 10 failed sign-ins for account "provider1" from one address
    Then the next sign-in attempt should be throttled
    And the response status should be 429
    And the response should include a "Retry-After" header

  Scenario: A throttled account is not locked out permanently
    Given account "provider1" is throttled after repeated failures
    When the throttle window elapses
    Then a correct sign-in for "provider1" should succeed

  Scenario: Throttling is keyed by identity as well as address
    When I submit 10 failed sign-ins for account "provider1" from 10 different addresses
    Then the next sign-in attempt for "provider1" should be throttled

  Scenario: One throttled account does not throttle the clinic
    Given account "provider1" is throttled after repeated failures
    When account "provider2" signs in from the same address
    Then the sign-in should succeed

  # ---------------------------------------------------------------------------
  # Public tokenized links
  # ---------------------------------------------------------------------------

  Scenario: Token redemption is throttled by address
    When 30 unknown consent tokens are redeemed from one address
    Then the next token redemption from that address should be throttled

  Scenario: A throttled miss is indistinguishable from a throttled hit
    Given a valid consent token exists
    And the address has been throttled for token redemption
    When the valid token is redeemed from that address
    And an unknown token is redeemed from that address
    Then both responses should be identical
    And neither response should reveal whether the token existed

  Scenario: Token redemption failures are recorded for review
    When 30 unknown consent tokens are redeemed from one address
    Then an audit event should record the repeated token redemption failures

  # ---------------------------------------------------------------------------
  # Clinical read surface
  # ---------------------------------------------------------------------------

  Scenario: Patient search is throttled per authenticated session
    Given I am authenticated with SMART-on-FHIR
    When I issue 200 patient searches within the throttle window
    Then the next patient search should be throttled

  Scenario: Throttled clinical reads are audited, not silently dropped
    Given I am authenticated with SMART-on-FHIR
    And my session has been throttled for patient search
    When I issue another patient search
    Then an audit event should exist with outcome "4"

  # ---------------------------------------------------------------------------
  # Coverage is the deliverable
  # ---------------------------------------------------------------------------

  Scenario: Every route is throttled or explicitly allowlisted
    When the rate-limit convention check runs
    Then every route should be either throttled or on the reviewed allowlist

  Scenario: A newly added route that is neither fails the check
    Given a route exists that is neither throttled nor allowlisted
    When the rate-limit convention check runs
    Then the check should fail
    And the failure should name the route
