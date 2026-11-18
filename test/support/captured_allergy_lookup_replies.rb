# frozen_string_literal: true

# Replies RPMS sent for allergy entry's two lookups (#1109), line for line,
# from a container of the build rpms-rpc pins (bcer-9.0-20261012-e7923a4-ydb),
# signed on as PMD123 in CIAV VUECENTRIC. ORWDAL32 ALLERGY MATCH for STRAWB is
# also in rpms-rpc's test/fixtures/captured_replies/allergen.yml. Seeded into
# the mock broker so the form's lookups parse what RPMS really sends.
module CapturedAllergyLookupReplies
  # ORWDAL32 ALLERGY MATCH, "STRAWB": GMR ALLERGIES by name and by synonym.
  ALLERGEN_STRAWB = [
    "1^VA Allergies File^^^TOP^+",
    "6^STRAWBERRIES^GMRD(120.82,\"B\")^DF^1",
    "6^STRAWBERRIES <STRAWBERRY>^GMRD(120.82,\"D\")^DF^1",
    "3^National Drug File - Generic Drug Name^^^TOP^+",
    "4^National Drug file - Trade Name^^^TOP^+",
    "5^Local Drug File^^^TOP^+",
    "7^Drug Ingredients File^^^TOP^+",
    "8^VA Drug Class File^^^TOP^+"
  ].freeze

  # ORWDAL32 ALLERGY MATCH, "STRAWBERRIES": the search the form repeats
  # before filing a chosen allergen.
  ALLERGEN_STRAWBERRIES = [
    "1^VA Allergies File^^^TOP^+",
    "6^STRAWBERRIES^GMRD(120.82,\"B\")^DF^1",
    "3^National Drug File - Generic Drug Name^^^TOP^+",
    "4^National Drug file - Trade Name^^^TOP^+",
    "5^Local Drug File^^^TOP^+",
    "7^Drug Ingredients File^^^TOP^+",
    "8^VA Drug Class File^^^TOP^+"
  ].freeze

  # ORWDAL32 SYMPTOMS, FROM "RAR~", DIR 1: the page after RAR~, where names
  # starting RAS begin (the form's FROM for "RAS"). The first eight of its rows.
  SYMPTOMS_FROM_RAR = [
    "133^RASH",
    "378^RECTAL HEMORRHAGE",
    "501^RED EYE",
    "78^RED SKIN\t<ERYTHEMA>^ERYTHEMA",
    "379^REDUCED LIBIDO",
    "270^REFLUX\t<GASTROESOPHAGEAL REFLUX>^GASTROESOPHAGEAL REFLUX",
    "380^RENAL AZOTEMIA",
    "381^RENAL FAILURE SYNDROME"
  ].freeze

  def seed_allergy_lookups!(client = RpmsRpc.client)
    client.seed_raw_lines(:allergen_match, "STRAWB", ALLERGEN_STRAWB)
    client.seed_raw_lines(:allergen_match, "STRAWBERRIES", ALLERGEN_STRAWBERRIES)
    client.seed_raw_lines(:symptom_search, "RAR~", SYMPTOMS_FROM_RAR)
  end
end
