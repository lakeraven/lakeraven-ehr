Feature: Care Coordination with External Systems
  As a healthcare administrator
  I want to share patient data with external care partners
  So that patients receive coordinated care across different providers

  Background:
    Given the following patients exist:
      | dfn | first_name | last_name | dob        | sex | ssn         | tribal_enrollment | tribal_affiliation                    | service_area |
      | 1   | Alice      | Anderson  | 1980-05-15 | F   | 111-11-1111 | ANLC-12345       | Alaska Native - Anchorage (ANLC)      | Anchorage    |

  Scenario: External system requests patient information
    Given patient "Anderson, Alice" has consented to data sharing
    When an authorized external system requests patient data
    Then patient demographics are provided in a standard format
    And tribal affiliation is included
    And enrollment information is available for eligibility checks
    And the data format is compatible with national health networks

  Scenario: Sending service request to care navigation platform
    Given patient "Anderson, Alice" needs specialty care
    And a service request has been created for cardiology
    When the service request is submitted to the care navigation platform
    Then the platform receives all required patient information
    And service request details are included
    And funding source information is provided
    And the platform can process the service request automatically

  Scenario: Receiving care recommendations from external platform
    Given patient "Anderson, Alice" has an active service request
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
    Given patient "Anderson, Alice" has sensitive tribal enrollment data
    When patient information is shared with external systems
    Then only authorized systems can access the data
    And tribal-specific information is properly protected
    And audit logs record all data access
    And the patient can review who accessed their information

  Scenario: Handling external system outages gracefully
    Given the care navigation platform is temporarily unavailable
    When I attempt to submit a service request
    Then the system queues the service request for later submission
    And I am notified of the delay
    And the service request is automatically submitted when the platform returns
