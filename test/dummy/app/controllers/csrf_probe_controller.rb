# frozen_string_literal: true

# Probes for the session-write landing contract (#486 / #491).
#
# The contract is "a session-derived token may not write where forgery
# protection is not actually enforced", so proving it needs routes on BOTH
# sides of that line. #486 alone has no CSRF-protected WebController write
# route of its own (#491's screening surface is the first), and a contract
# asserted only against routes that do not exist is not a tested contract.
#
# These live in the dummy host app and are never shipped.

# Protected: a normal WebController descendant. verify_authenticity_token is in
# the chain, so a browser session MAY write here — subject to everything else.
class CsrfProbeController < Lakeraven::EHR::WebController
  include Lakeraven::EHR::SmartAuthentication

  before_action :authenticate_smart_token!
  before_action :authorize_probe_scope!

  def create
    Lakeraven::EHR::ReconciliationSession.create!(
      patient_dfn: params[:patient_dfn].to_s, clinician_duz: current_duz.to_s,
      source_type: "csrf-probe", status: "pending"
    )
    render plain: "written", status: :created
  end

  private

  # Models #491's screening surface: a CSRF-protected WebController that opts
  # into browser-session auth. The FHIR API (ActionController::API) never does
  # — that scoping is exactly what #512 F1 / #525 require.
  def session_token_fallback_allowed?
    true
  end

  def authorize_probe_scope!
    return if can_write?(fhir_resource_type)

    render_forbidden("Insufficient scope for writing #{fhir_resource_type}")
  end

  # A type a keyed clinician can actually hold write scope for, so the probe
  # exercises the contract rather than tripping on scope first.
  def fhir_resource_type = "ServiceRequest"
end
