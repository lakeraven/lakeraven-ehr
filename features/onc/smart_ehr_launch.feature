@onc @app
Feature: SMART EHR Launch
  As an ONC-certified EHR system
  The SMART EHR launch endpoint should follow the SMART App Launch Framework
  So that apps can be launched from within the EHR per 170.315(g)(10)(iii)

  ONC 170.315(g)(10)(iii) - Application registration and EHR launch.
  A signed-in user opens a patient in a registered app; the app is sent to its
  registered launch URI with iss and launch (test/integration/smart_launch_context_test.rb).

  Scenario: EHR launch needs a signed-in user
    When I request GET "/smart/launch?patient=3" without authentication
    Then the response should redirect to the sign-in page

  Scenario: the style a launched app may follow is served as JSON
    When I request GET "/smart/style" without authentication
    Then the response status should be 200
    And the response JSON should include "sms_style_version"
