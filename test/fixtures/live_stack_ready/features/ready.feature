Feature: A ready stack run reports a scenario as run only with evidence
  The repo's real ready-path hooks over a fake broker client (#962). Each
  scenario is run alone by test/lib/live_stack_ready_cucumber_test.rb.

  Scenario: The persona reads from the stack
    When the persona reads from the stack

  Scenario: Nothing is read
    When nothing is read

  Scenario: The stack refuses an RPC
    When the stack refuses an RPC

  Scenario: The app swallows a refused RPC
    When the app swallows a refused RPC

  Scenario: Another client answers
    When another client answers

  Scenario: The client signs on as someone else
    When the client signs on as someone else

  Scenario: A gateway is stubbed
    When a gateway is stubbed

  Scenario: A gateway is stubbed bare
    When a gateway is stubbed bare

  Scenario: The mock answers through its lines
    When the mock answers through its lines

  Scenario: The mock answers through its global array
    When the mock answers through its global array

  Scenario: The clock is moved
    When the clock is moved and the persona reads from the stack

  Scenario: The clock is moved and a gateway is stubbed bare
    When the clock is moved and a gateway is stubbed bare

  Scenario: The app swallows an error from the mock
    When the app swallows an error from the mock

  Scenario: The persona reads from the stack and a check fails
    When the persona reads from the stack
    Then a check fails

  # #1179 round 2. These stay below "Nothing is read": cucumber runs in file
  # order, and one test names the first reason in that order.
  Scenario: A step is pending
    When a step is pending

  Scenario: A step has no definition
    When a step nobody defined is used

  Scenario: The first attempt fails and the second reads nothing
    When the first attempt fails and the second reads nothing

  Scenario: A step skips the scenario itself
    When a step skips the scenario itself
