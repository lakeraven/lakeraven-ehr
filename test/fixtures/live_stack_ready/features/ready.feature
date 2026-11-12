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
