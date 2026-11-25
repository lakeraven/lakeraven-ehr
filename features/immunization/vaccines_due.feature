@vaccines_due
Feature: See the vaccines a patient is due for
  As a provider at a patient's visit
  I want RPMS's immunization forecast in front of me
  So that a vaccine the patient is due for is not missed

  # lakeraven-ehr#865. The forecast is the Immunization package's call to its
  # outside forecaster. The pinned demo build ships forecasting switched off
  # in its Immunization site parameters, so RPMS answers its reason instead of
  # a due list, and the page must say so rather than show nothing due.

  @live
  Scenario: A build that produced no forecast says why, and lists nothing as due
    Given the provider has opened the record of patient "2" with immunization read
    When the provider opens the patient's vaccines due
    Then the page says RPMS did not produce an immunization forecast
    And the page quotes the Immunization package's reason "Immunization Forecasting disabled (see Site Parameters)."
    And no vaccine is listed as due
