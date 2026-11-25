# frozen_string_literal: true

require "rpms_rpc/mock_client"

# Mock seeds for the sensitive-patient check on opening a record (#613):
# DG SENSITIVE RECORD ACCESS (PTSEC^DGSEC4) and DG SENSITIVE RECORD BULLETIN
# (NOTICE^DGSEC4), as RpmsRpc::DgSensitive sends them.
#
# The seeds are WIRE reply lines, so the gem's own parser reads them:
#   access:   one line per RESULT node, the first is the code ("0", "2", ...),
#             the rest are RPMS's message lines. No typed header.
#   bulletin: the single value "1" (logged and sent) or "0".
# Shapes are those of rpms-rpc test/fixtures/captured_replies/dg-sensitive.yml.
#
# DG SENSITIVE RECORD ACCESS has no DataMapper mapping (the gem reads it with
# call_rpc and parses the lines itself), so MockClient#seed_raw_lines cannot
# name it. The lines go where seed_raw_lines puts them: the mock's per-RPC
# table of raw line replies, keyed by the first parameter, the DFN.
#
# An RPC nothing was seeded for answers "" on the mock, which the gem reads as
# nil: RPMS did not answer. That is never "not sensitive", so a record whose
# check was not seeded does not open. Every existing test that opens a record
# therefore needs the "0" a real broker sends for a record that is not
# sensitive: seed_demo_patients_not_sensitive! is that default.
module SensitivePatientAccessSeeds
  ACCESS_RPC = "DG SENSITIVE RECORD ACCESS"
  BULLETIN_RPC = "DG SENSITIVE RECORD BULLETIN"
  OPTION = "OR CPRS GUI CHART"
  LOG_AND_SEND = "3"

  # PTSEC^DGSEC4's warning for a sensitive record, verbatim from the captured
  # reply (dg-sensitive.yml, sensitive/1). RPMS's own text: no patient data.
  WARNING_LINES = [
    "***WARNING***",
    "***RESTRICTED RECORD***",
    "* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * ",
    "* This record is protected by the Privacy Act of 1974 & Health Insurance*",
    "* Portability & Accountability Act of 1996. If you elect to proceed, you*",
    "* must prove you have a need to know.  Access to this patient is tracked*",
    "* and your Security Officer will contact you for your justification.    *",
    "* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * "
  ].freeze

  # The DFNs BASELINE_MOCK_SEEDS (test/test_helper.rb) and LakeravenDemoSeeds
  # (test/dummy/lib/lakeraven_demo_seeds.rb, DFN 1 and its panel 2-7) seed.
  BASELINE_DFNS = %w[1 2 3 4 5 6 7].freeze

  module_function

  # Every synthetic demo patient the suite opens answers "0", not sensitive:
  # the baseline and demo-seed DFNs, and the demo site's (features/support/
  # rpms_demo_site.rb) when that is loaded. Takes the MockClient being seeded.
  def seed_demo_patients_not_sensitive!(client = RpmsRpc.client)
    dfns = BASELINE_DFNS.dup
    dfns.concat(RpmsDemoSite::PATIENTS.keys.map(&:to_s)) if defined?(RpmsDemoSite::PATIENTS)
    seed_not_sensitive!(*dfns.uniq, client: client)
  end

  # RPMS answers 0 for each DFN: no warning needed.
  def seed_not_sensitive!(*dfns, client: RpmsRpc.client)
    dfns.flatten.each { |dfn| seed_sensitive_access!(dfn, 0, client: client) }
  end

  # RPMS answers `code` and `messages` for DFN, as reply lines.
  def seed_sensitive_access!(dfn, code, messages = [], client: RpmsRpc.client)
    seed_access_reply!(dfn, [ code.to_s, *messages ], client: client)
  end

  # The raw reply lines for DFN, for replies that are not a code at all.
  def seed_access_reply!(dfn, lines, client: RpmsRpc.client)
    return unless mock?(client)

    table = client.instance_variable_get(:@lines) || {}
    (table[ACCESS_RPC] ||= {})[dfn.to_s] = Array(lines).map(&:to_s)
    client.instance_variable_set(:@lines, table)
  end

  # RPMS does not answer the check for DFN (the mock's "" for an RPC nothing
  # was seeded for), whatever default was seeded before.
  def clear_sensitive_access!(dfn, client: RpmsRpc.client)
    return unless mock?(client)

    client.instance_variable_get(:@lines)&.dig(ACCESS_RPC)&.delete(dfn.to_s)
  end

  # NOTICE^DGSEC4's single value for DFN: "1" when it wrote the DG SECURITY
  # LOG entry and sent the bulletin, "0" when it did not.
  def seed_sensitive_bulletin!(dfn, success, client: RpmsRpc.client)
    return unless mock?(client)

    client.seed_scalar(:dg_sensitive_bulletin, dfn.to_s, success ? "1" : "0")
  end

  def sensitive_access_calls(client = RpmsRpc.client)
    client.received_calls.select { |call| call[:rpc] == ACCESS_RPC }
  end

  def sensitive_bulletin_calls(client = RpmsRpc.client)
    client.received_calls.select { |call| call[:rpc] == BULLETIN_RPC }
  end

  def mock?(client) = client.is_a?(RpmsRpc::MockClient)
end
