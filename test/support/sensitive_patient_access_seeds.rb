# frozen_string_literal: true

require_relative "rpms_stand_in"

# Stand-in answers for the sensitive-patient check on opening a record (#613):
# what RpmsRpc::DgSensitive.check_access (DG SENSITIVE RECORD ACCESS,
# PTSEC^DGSEC4) and .record_bulletin (DG SENSITIVE RECORD BULLETIN,
# NOTICE^DGSEC4) answer the engine's SensitiveRecordGateway.
#
#   check_access:   { result: 0..4, messages: [...] }, RPMS's code and its
#                   message lines, or nil when RPMS did not answer a code.
#   record_bulletin: { success: true } when RPMS wrote the DG SECURITY LOG
#                   entry and sent the bulletin, { success: false } when not.
#
# A check nothing answers reads nil: RPMS did not answer. That is never "not
# sensitive", so a record whose check has no answer does not open. Every test
# that opens a record therefore needs the 0 RPMS answers for a record that is
# not sensitive: seed_demo_patients_not_sensitive! is that default.
module SensitivePatientAccessSeeds
  ACCESS_RPC = "DG SENSITIVE RECORD ACCESS"
  BULLETIN_RPC = "DG SENSITIVE RECORD BULLETIN"
  OPTION = "OR CPRS GUI CHART"
  LOG_AND_SEND = 3

  # PTSEC^DGSEC4's warning for a sensitive record, verbatim from a reply
  # captured from the build (rpms-rpc test/fixtures/captured_replies/
  # dg-sensitive.yml, sensitive/1). RPMS's own text: no patient data.
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

  module_function

  # Every synthetic patient the suite opens answers 0, not sensitive: the
  # baseline and demo-seed DFNs, and the demo site's (features/support/
  # rpms_demo_site.rb) when that is loaded.
  def seed_demo_patients_not_sensitive!
    dfns = RpmsStandIn::Baseline::NOT_SENSITIVE_DFNS.dup
    dfns.concat(RpmsDemoSite::PATIENTS.keys) if defined?(RpmsDemoSite::PATIENTS)
    seed_not_sensitive!(*dfns.uniq)
  end

  # RPMS answers 0 for each DFN: no warning needed.
  def seed_not_sensitive!(*dfns)
    RpmsStandIn.not_sensitive(*dfns)
  end

  # RPMS answers `code` and `messages` for DFN.
  def seed_sensitive_access!(dfn, code, messages = [])
    RpmsStandIn.sensitive(dfn, result: Integer(code), messages: messages)
  end

  # RPMS does not answer a code for DFN, whatever default was answered before.
  def clear_sensitive_access!(dfn)
    RpmsStandIn.sensitive(dfn, result: nil)
  end

  # Whether RPMS wrote the DG SECURITY LOG entry and sent the bulletin for DFN.
  def seed_sensitive_bulletin!(dfn, success)
    RpmsStandIn.sensitive_bulletin(dfn, success: success)
  end

  # The checks the engine asked for: each call's keywords
  # ({ dfn:, generate_message:, option: }).
  def sensitive_access_calls
    RpmsStandIn.calls(RpmsRpc::DgSensitive, :check_access).map { |call| call[:kwargs] }
  end

  # The bulletins the engine asked for: { dfn:, action:, option: }.
  def sensitive_bulletin_calls
    RpmsStandIn.calls(RpmsRpc::DgSensitive, :record_bulletin).map { |call| call[:kwargs] }
  end
end
