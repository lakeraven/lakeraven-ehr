# frozen_string_literal: true

# Steps shared by every rpms-ux scenario in features/bprm_twin/ (lakeraven-ehr#565).
#
# Each scenario there is tagged with the rpms-ux scenario id it proves
# (`@S-REG-02.1`); docs/bprm/README.md says where the ids come from and
# bin/bprm_coverage keeps them honest.
#
# Two kinds of scenario use these steps:
#
#   * A STUB (features/bprm_twin/stubs/*.feature, generated): its first step
#     is `this scenario waits on "..."`, which PENDS and names what is missing.
#     The quoted Given/When/Then lines that follow are the story's own words,
#     carried so the stub says what a user does and what FileMan state is
#     asserted. They are matched by the one-string step below, which also
#     pends, so a stub can never pass silently (lakeraven-ehr#484): remove the
#     waits-on line and the scenario is still pending until real steps drive
#     it.
#   * A DRIVEN scenario (features/bprm_twin/<workflow>/*.feature, hand
#     written): signs on as its persona, then uses concrete Capybara steps.
#
# Persona users (rpms-ux PERSONAS.md) are not defined on any stack yet, so the
# sign-on here seeds the browser session through the test-only
# TestSessionsController with a synthetic DUZ per persona. No RPMS user is
# behind it: a pass through these steps says the screen does the right thing
# against the configured broker (RpmsRpc.mock! in test_helper.rb), not that
# the persona's RPMS user could do it.

ParameterType(
  name: "persona",
  regexp: /front desk clerk|registration supervisor|scheduler|admissions clerk|nurse|him technician|benefits coordinator/,
  transformer: ->(words) { words.tr(" ", "_") }
)

module BprmScenarioHelpers
  # Synthetic DUZ per persona: stable so audit rows and received RPC calls can
  # be attributed in assertions. Nothing on a stack holds these.
  # `rpms_keys` are the RPMS security keys the persona holds (PERSONAS.md:
  # the keys BPRM's Policies.cs gates each role on); the screens gate on
  # these names (WebController#require_rpms_key!).
  PERSONA_USERS = {
    "front_desk_clerk" => { duz: "99901", user_name: "CLERK,FRONTDESK", rpms_keys: %w[AGZMENU SDZMENU] },
    "registration_supervisor" => { duz: "99907", user_name: "SUPERVISOR,REGISTRATION",
                                   rpms_keys: %w[AGZMGR AGZMENU AGZVIEWSSN] },
    "scheduler" => { duz: "99902", user_name: "CLERK,SCHEDULING", rpms_keys: %w[SDZMENU SDZREGMENU] },
    "admissions_clerk" => { duz: "99903", user_name: "CLERK,ADMISSIONS", rpms_keys: %w[DGZMENU DGZADT] },
    "nurse" => { duz: "99904", user_name: "NURSE,WARD", rpms_keys: %w[DGZNUR] },
    "him_technician" => { duz: "99905", user_name: "TECH,HIM", rpms_keys: %w[DGZICE] },
    "benefits_coordinator" => { duz: "99906", user_name: "COORDINATOR,BENEFITS", rpms_keys: %w[AGZMENU AGZCREOPN] }
  }.freeze

  def sign_on_as(persona, rpms_keys: nil)
    user = PERSONA_USERS.fetch(persona)
    keys = rpms_keys || user[:rpms_keys]
    page.driver.post(engine_path("/test_session"),
                     duz: user[:duz], user_name: user[:user_name], user_type: persona, rpms_keys: keys)
    @persona = persona
    @persona_user = user
  end

  def received_rpc_calls(rpc_name)
    RpmsRpc.client.received_calls.select { |call| call[:rpc] == rpc_name }
  end
end
World(BprmScenarioHelpers)

BPRM_SCENARIO_TAG = /\A@S-[A-Z]+-\d+\.\d+\z/

Before do |scenario|
  # Every scenario that names an rpms-ux id starts from a clean broker call
  # log, so "the RPC was called with" assertions see only its own traffic.
  next unless scenario.tags.any? { |tag| tag.name.match?(BPRM_SCENARIO_TAG) }

  RpmsRpc.client.received_calls.clear if RpmsRpc.client.respond_to?(:received_calls)
end

Given("this scenario waits on {string}") do |what|
  pending("waits on: #{what}")
end

# The story's own Given/When/Then, quoted. Never a pass: a stub whose
# waits-on line was removed still pends here until concrete steps replace
# these lines.
Given("{string}") do |story_text|
  pending("not driven: #{story_text}")
end

Given("the {persona} is signed on") do |persona|
  sign_on_as(persona)
end

# The key-refusal scenarios: a user in the persona's role signed on with
# only the named keys ("no keys" for none).
Given("the {persona} is signed on holding only {string}") do |persona, keys|
  held = keys == "no keys" ? [] : keys.split(",").map(&:strip)
  sign_on_as(persona, rpms_keys: held)
end
