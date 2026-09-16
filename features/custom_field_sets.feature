@site_config @pending
Feature: Site-specific discrete fields as custom field sets
  As a site administrator with locally-required data to capture
  I need to define discrete fields without changing engine code
  So that the site's requirements do not become a fork of the engine

  # Specification ahead of implementation (#500). Today the only way to add a
  # locally-required discrete field is to change engine code, which pushes
  # site-specific (L3) data into the shared engine (L1). Values belong in a
  # site-owned FileMan file, not in engine tables — the site's data stays in
  # the site's database. Steps are intentionally undefined rather than
  # stubbed (#484).
  #
  # Out of scope: a general form builder.

  Background:
    Given the following patients exist:
      | dfn | first_name | last_name | dob        | sex |
      | 1   | Alice      | Anderson  | 1980-05-15 | F   |
    And a site-owned custom data file exists

  # ---------------------------------------------------------------------------
  # Defining
  # ---------------------------------------------------------------------------

  Scenario: An administrator defines a custom field set bound to a screen
    When I define a custom field set "Program Enrollment" bound to entity "Patient" and screen "registration" with fields:
      | name            | type    | required |
      | program_code    | code    | true     |
      | enrolled_on     | date    | true     |
      | funding_source  | string  | false    |
    Then the field set should be saved
    And the field set should be tagged as layer "L3"

  Scenario: A definition whose backing data dictionary does not exist is refused
    When I define a custom field set backed by a data dictionary that does not exist
    Then the definition should be rejected
    And the error should name the missing data dictionary
    And nothing should be written

  Scenario: A definition bound to an unknown screen is refused
    When I define a custom field set bound to screen "nonexistent"
    Then the definition should be rejected

  Scenario: A custom field may not shadow an engine field
    When I define a custom field named "date_of_birth" on entity "Patient"
    Then the definition should be rejected as conflicting with an engine field

  # ---------------------------------------------------------------------------
  # Capturing values
  # ---------------------------------------------------------------------------

  Scenario: Values are written to the site-owned file, not to engine tables
    Given a custom field set "Program Enrollment" is defined for entity "Patient"
    When I save custom values for patient "1":
      | field        | value      |
      | program_code | EXAMPLE01  |
      | enrolled_on  | 2026-10-01 |
    Then the values should be persisted in the site-owned custom data file
    And no engine table should hold the values

  Scenario: Saved values are readable back for the patient
    Given patient "1" has custom value "program_code" of "EXAMPLE01"
    When I read the custom field set for patient "1"
    Then "program_code" should be "EXAMPLE01"

  Scenario: A required custom field is enforced on save
    Given a custom field set with required field "program_code" is defined
    When I save custom values for patient "1" omitting "program_code"
    Then the save should be rejected
    And the error should name "program_code"

  Scenario: A typed custom field rejects a value of the wrong type
    Given a custom field set with date field "enrolled_on" is defined
    When I save "not-a-date" into "enrolled_on" for patient "1"
    Then the save should be rejected

  # ---------------------------------------------------------------------------
  # Boundaries — truncation is worse than refusal
  # ---------------------------------------------------------------------------

  Scenario: A value exceeding the transport limit is refused, not truncated
    Given a custom field set with string field "notes" is defined
    When I save a value longer than the transport parameter limit into "notes"
    Then the save should be rejected
    And the error should state the limit
    And no partial value should be persisted

  # ---------------------------------------------------------------------------
  # Rendering
  # ---------------------------------------------------------------------------

  Scenario: The screen renders custom fields from metadata without a code change
    Given a custom field set "Program Enrollment" is bound to screen "registration"
    When I open the "registration" screen for patient "1"
    Then the screen should render the "program_code" field
    And the field should be labelled from the definition
    And the field should enforce its declared type

  Scenario: A site with no custom field sets renders the screen unchanged
    Given no custom field sets are defined
    When I open the "registration" screen for patient "1"
    Then the screen should render no custom field section

  # ---------------------------------------------------------------------------
  # Overlay capture
  # ---------------------------------------------------------------------------

  Scenario: Custom field definitions are captured in the site overlay
    Given a custom field set "Program Enrollment" is defined
    When the site overlay is captured
    Then the overlay should include the "Program Enrollment" definition
    And the overlay entry should be tagged as layer "L3"

  Scenario: Rebuilding a site from its overlay restores its custom fields
    Given a site overlay containing a "Program Enrollment" definition
    When the site is rebuilt from the overlay
    Then the "Program Enrollment" field set should be defined
    And the "registration" screen should render its fields

  # ---------------------------------------------------------------------------
  # Audit
  # ---------------------------------------------------------------------------

  Scenario: Changing a definition is audited
    Given a custom field set "Program Enrollment" is defined
    When I add a field to the definition
    Then an audit event should record the definition change
