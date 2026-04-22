@breach_detection
Feature: Breach Detection
  As a HIPAA-compliant system
  Suspicious activity should trigger security incidents
  So that breaches are detected per 45 CFR 164.400-414

  Scenario: Repeated failed logins trigger security incident
    Given 6 failed login attempts from IP "10.0.0.1" within 15 minutes
    When the security monitor runs
    Then a security incident should exist for IP "10.0.0.1"
    And the incident severity should be "high"
    And the incident status should be "open"

  Scenario: Duplicate incidents are deduplicated
    Given 6 failed login attempts from IP "10.0.0.2" within 15 minutes
    And the security monitor has already created an incident for IP "10.0.0.2"
    When the security monitor runs again
    Then there should be exactly 1 open incident for IP "10.0.0.2"

  Scenario: Incident storm triggers per-type backoff
    Given more than 10 open brute_force security incidents exist
    And 6 failed login attempts from IP "10.0.0.3" within 15 minutes
    Then running the security monitor should not create new brute_force incidents
