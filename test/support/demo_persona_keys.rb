# frozen_string_literal: true

# The SECURITY KEYs the build gives each demo persona user (rpms-ops SEEDPERS,
# from the analyst's profiles in rpms-ux profiles.json). Used by
# PersonaScopesTest (no RPC) and LivePersonaScopesTest (a real RPMS).
module DemoPersonaKeys
  BY_PERSONA = {
    "PROFILE,MD" => [ "PROVIDER", "ORES", "BMCZMENU" ],
    "PROFILE,RN" => [ "PROVIDER", "ORELSE" ],
    "PROFILE,MA" => [ "PROVIDER", "OREMAS" ],
    "PROFILE,REG" => [ "AGZMENU" ],
    "PROFILE,SCHED" => [ "SDZMENU" ]
  }.freeze
end
