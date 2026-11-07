# frozen_string_literal: true

# The SECURITY KEYs and options the build gives each demo persona user (rpms-ops
# SEEDPERS, from the analyst's profiles in rpms-ux profiles.json). Used by
# PersonaScopesTest (no RPC) and LivePersonaScopesTest (a real RPMS).
module DemoPersonaKeys
  BY_PERSONA = {
    "PROFILE,MD" => [ "PROVIDER", "ORES", "BMCZMENU" ],
    "PROFILE,RN" => [ "PROVIDER", "ORELSE" ],
    "PROFILE,MA" => [ "PROVIDER", "OREMAS" ],
    "PROFILE,REG" => [ "AGZMENU" ],
    "PROFILE,SCHED" => [ "SDZMENU" ]
  }.freeze

  # The options the policy asks about that each persona may run. Every persona
  # holds CIAV VUECENTRIC, as a secondary menu option: it is the context a CIA
  # sign-on binds to, so everyone who signs on to VueCentric holds it.
  OPTIONS_BY_PERSONA = BY_PERSONA.keys.to_h { |persona| [ persona, [ "CIAV VUECENTRIC" ] ] }.freeze
end
