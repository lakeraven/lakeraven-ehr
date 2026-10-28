@eprescribing_gateway
Feature: E-prescribing gateway for external clinical front ends
  As a prescriber using any clinical front end over a VistA or RPMS system
  I want to send, renew and receive electronic prescriptions through the gateway's REST API
  So that e-prescribing works without an InterSystems interface engine or the VA central eRx hub

  The gateway talks to the e-prescribing network through a certified
  intermediary adapter. Front ends call the gateway's REST API; the gateway
  never depends on which front end called it. The same scenarios hold for
  this engine's own UI, which is one more client of the same API.

  Background:
    Given an e-prescribing intermediary that accepts NCPDP SCRIPT transactions
    And a stock VistA site connected to the gateway over the RPC broker
    And an API client authorized for the e-prescribing scope
    And a patient with ICN "1012345678V123456" at the site
    And a prescriber with NPI "1234567893" and an active DEA registration
    And a retail pharmacy with NCPDP ID "1234567" in the pharmacy directory

  # ===========================================================================
  # FLOW 1: A prescriber sends a new prescription to an outside pharmacy
  # ===========================================================================

  Scenario Outline: Send a new prescription to an outside pharmacy from any front end
    Given the API client is <client>
    And the client has saved the order to VistA as a non-VA medication
    When the client posts a prescription for "Lisinopril 10 MG Oral Tablet" to the pharmacy
    Then the response status should be 202
    And the response should include a prescription id
    And the intermediary should receive a NewRx for that patient, prescriber and pharmacy
    And the prescription status should be "transmitted"

    Examples:
      | client                                                       |
      | this engine's prescriber UI                                  |
      | an external web front end for a VistA site running on IRIS   |
      | an external web front end for a VistA site running on YottaDB |

  Scenario: An external front end needs only the published API contract
    When the client fetches the gateway's OpenAPI document
    Then it should describe the prescription, status, cancel, renewal and change endpoints
    And it should describe the signing evidence required for controlled substances
    And it should describe the status notification callback

  Scenario: Pharmacy confirms receipt
    Given a prescription the gateway has transmitted
    When the intermediary delivers a Status message for it
    Then the prescription status should be "delivered"
    And the client should be notified of the status change

  Scenario: Pharmacy rejects the prescription
    Given a prescription the gateway has transmitted
    When the intermediary delivers an Error message "Pharmacy not accepting e-prescriptions"
    Then the prescription status should be "error"
    And the error text should be available to the client

  Scenario: A prescription missing required fields is rejected before transmission
    When the client posts a prescription with no pharmacy
    Then the response status should be 422
    And nothing should be sent to the intermediary

  Scenario: The client checks a prescription's status
    Given a prescription the gateway has transmitted
    When the client requests that prescription's status
    Then the response should include the current status and its history

  Scenario: The prescriber cancels a transmitted prescription
    Given a prescription the gateway has transmitted
    When the client cancels it with reason "Patient allergy"
    Then the intermediary should receive a CancelRx for it
    And the prescription status should be "cancel requested"

  # ===========================================================================
  # CONTROLLED SUBSTANCES (EPCS)
  # ===========================================================================

  Scenario: A controlled substance requires two-factor signing evidence
    When the client posts a prescription for Schedule "II" medication "Hydrocodone 5 MG Oral Tablet" without signing evidence
    Then the response status should be 422
    And the error should say two-factor signing evidence is required
    And nothing should be sent to the intermediary

  Scenario: A controlled substance with signing evidence is transmitted
    When the client posts a prescription for Schedule "II" medication "Hydrocodone 5 MG Oral Tablet" with two-factor signing evidence
    Then the intermediary should receive a NewRx flagged as a controlled substance
    And an audit event should record the signing evidence and the prescriber's DEA number

  Scenario: A prescriber without a DEA registration cannot prescribe a controlled substance
    Given the prescriber has no DEA registration
    When the client posts a prescription for Schedule "IV" medication "Alprazolam 0.5 MG Oral Tablet" with two-factor signing evidence
    Then the response status should be 422
    And nothing should be sent to the intermediary

  # ===========================================================================
  # FLOW 2: A pharmacy asks the prescriber for a renewal or a change
  # ===========================================================================

  Scenario: A renewal request reaches the prescriber's inbox
    Given a prescription the gateway has transmitted
    When the intermediary delivers an RxRenewalRequest for it
    Then the client should see a pending renewal request for the prescriber

  Scenario: The prescriber approves a renewal
    Given a pending renewal request
    And the client has saved the renewed order to VistA as a non-VA medication
    When the client approves the renewal
    Then the intermediary should receive an approved RxRenewalResponse
    And the renewal request status should be "approved"

  Scenario: The prescriber denies a renewal
    Given a pending renewal request
    When the client denies the renewal with reason "Patient needs an office visit"
    Then the intermediary should receive a denied RxRenewalResponse with that reason
    And the renewal request status should be "denied"

  Scenario: The prescriber approves a pharmacy change request
    Given a prescription the gateway has transmitted
    And the intermediary has delivered an RxChangeRequest to "Lisinopril 20 MG Oral Tablet"
    When the client approves the change
    Then the intermediary should receive an approved RxChangeResponse

  # ===========================================================================
  # FLOW 3: An outside prescriber sends a prescription to the site's pharmacy
  # (VistA's stock inbound eRx path; the gateway takes the VA hub's place)
  # ===========================================================================

  Scenario: An inbound prescription is placed in VistA's eRx holding queue
    Given the site has an outpatient pharmacy that accepts e-prescriptions
    When the intermediary delivers a NewRx addressed to the site's pharmacy
    Then the gateway should call INCERX on the site's VistA with the NCPDP SCRIPT message
    And VistA should report the prescription as received

  Scenario: VistA on IRIS reports a pharmacist's action back with no M changes
    Given a VistA site on IRIS whose PSO WEB SERVER points at the gateway
    And an inbound prescription the gateway has placed in VistA
    When VistA posts a status message to the gateway's hub endpoint
    Then the intermediary should receive a matching Status message for the outside prescriber

  Scenario: A site without a pharmacy refuses inbound prescriptions
    Given the site has no outpatient pharmacy
    When the intermediary delivers a NewRx addressed to the site
    Then the gateway should return an Error to the intermediary
    And nothing should be sent to VistA
