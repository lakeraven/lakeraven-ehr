Feature: Care Coordination with External Systems
  As a healthcare administrator
  I want to share patient data with external care partners
  So that patients receive coordinated care across different providers

  Background:
    Given these RPMS demo patients:
      | dfn | name             | ssn       | dob        | sex |
      | 4   | DEMO,PATIENT ONE | 666010101 | 2001-01-01 | F   |

  Scenario: External system requests patient information
    Given patient "DEMO,PATIENT ONE" has consented to data sharing
    When an authorized external system requests patient data
    Then patient demographics are provided in a standard format
    And the data format is compatible with national health networks

  # DEFERRED (@unsourced): depends on the tribal enrichment reverted here.
    # Only the TRIBAL assertions are deferred -- the sourced contract above
    # keeps running. Rebuilt under #566; do NOT make this green by seeding
    # the field again.
  @unsourced
  Scenario: External system receives tribal affiliation and enrollment
    Given patient "DEMO,PATIENT ONE" has consented to data sharing
    When an authorized external system requests patient data
    Then tribal affiliation is included
    And enrollment information is available for eligibility checks

  Scenario: Sending service request to care navigation platform
    Given patient "DEMO,PATIENT ONE" needs specialty care
    And a service request has been created for cardiology
    When the service request is submitted to the care navigation platform
    Then the platform receives all required patient information
    And service request details are included
    And funding source information is provided
    And the platform can process the service request automatically

  Scenario: Receiving care recommendations from external platform
    Given patient "DEMO,PATIENT ONE" has an active service request
    When the care navigation platform provides specialist recommendations
    Then I can see recommended providers
    And I can see estimated costs
    And I can see appointment availability
    And I can accept or modify the recommendations

  Scenario: Updating service request status from external system
    Given a service request was sent to the care navigation platform
    When the external platform approves the service request
    Then the status is updated automatically in our system
    And the clinician is notified
    And the patient can be informed of next steps

  Scenario: Ensuring data privacy during external sharing
    Given patient "DEMO,PATIENT ONE" has consented to data sharing
    When patient information is shared with external systems
    Then only authorized systems can access the data
    And audit logs record all data access
    And the patient can review who accessed their information

  # DEFERRED (@unsourced): depends on the tribal enrichment reverted here.
    # Only the TRIBAL assertions are deferred -- the sourced contract above
    # keeps running. Rebuilt under #566; do NOT make this green by seeding
    # the field again.
  @unsourced
  Scenario: Tribal-specific information is protected during external sharing
    Given patient "DEMO,PATIENT ONE" has sensitive tribal enrollment data
    When patient information is shared with external systems
    Then tribal-specific information is properly protected

  Scenario: Handling external system outages gracefully
    Given the care navigation platform is temporarily unavailable
    When I attempt to submit a service request
    Then the system queues the service request for later submission
    And I am notified of the delay
    And the service request is automatically submitted when the platform returns
