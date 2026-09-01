Feature: A walk-in visit charted end to end
  This is the demo script as an executable spec: a walk-in patient is seen,
  vitals are taken, the purpose of visit is recorded, a note is written and
  signed, and the encounter is closed. Every beat runs through the same
  service layer the app uses, against injected fake gateways.

  Scenario: Walk-in visit: vitals, POV, signed note, close
    Given a patient with DFN 8791
    And a demo visit with IEN 2090061
    And I am the authoring provider with DUZ 2843

    When the provider enters demo vitals TMP "98.9" F and BP "128/82" mmHg
    Then the demo vitals save should succeed

    When the provider records POV "J06.9" with narrative "Acute upper respiratory infection"
    Then the POV save should succeed

    When the provider creates a progress note with title 8927 and text:
      """
      S: Sore throat and congestion x3 days.
      A/P: Acute URI; supportive care.
      """
    Then the note create should succeed with a note IEN

    When the provider signs the note with signature code "DEMOPASS"
    Then the note signing should succeed

    When the provider closes the demo visit with reason "J06.9" "Acute upper respiratory infection"
    Then the demo visit should be finished
