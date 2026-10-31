Feature: Bulk Export Download Authentication
  As an ONC-certified EHR system
  Bulk export download, status, and cancel endpoints should require SMART authentication
  And enforce client ownership so one client cannot access another's exports
  Per § 170.315(g)(10)

  # URLs corrected: this feature addressed /fhir/bulk-export-files/:id/:file
  # and /fhir/$export-status/:id, neither of which is routed. The real routes
  # are `resources :exports` with nested files -- GET exports/:id (status),
  # DELETE exports/:id (cancel), GET exports/:export_id/files/:file_name
  # (download). Every scenario here was therefore hitting the Rails 404 HTML
  # page and asserting against it, so none of them exercised the ownership
  # concern they exist to protect.

  Background:
    Given the system is configured for FHIR API access

  Scenario: Download without authentication is rejected
    When I request GET "/fhir/exports/1/files/Patient.ndjson" without a Bearer token
    Then the response status should be 401
    And the response should be a FHIR OperationOutcome with code "login"

  Scenario: Status check without authentication is rejected
    When I request GET "/fhir/exports/1" without a Bearer token
    Then the response status should be 401
    And the response should be a FHIR OperationOutcome with code "login"

  Scenario: Cancel without authentication is rejected
    When I request DELETE "/fhir/exports/1" without a Bearer token
    Then the response status should be 401
    And the response should be a FHIR OperationOutcome with code "login"

  Scenario: Download with patient-only scope is forbidden
    Given I have a valid SMART token with scope "patient/Observation.read"
    When I request GET "/fhir/exports/1/files/Patient.ndjson" with the Bearer token
    Then the response status should be 403

  Scenario: Status check with valid system scope but wrong client is forbidden
    Given I have a valid SMART token with scope "system/*.read"
    And a bulk export exists for a different client
    When I check the status of the other client's export with my Bearer token
    # 404, NOT 403. ExportOwnership deliberately makes an export that is not
    # yours indistinguishable on the wire from one that does not exist: the
    # earlier 404-for-missing / 403-for-not-yours split was an existence
    # oracle. This scenario asserted that oracle -- expecting 403 and the
    # phrase "different client" in the body -- which is the disclosure the
    # concern removed. The distinction now survives in the log, where an
    # operator can act on it and an attacker cannot see it.
    Then the response status should be 404
