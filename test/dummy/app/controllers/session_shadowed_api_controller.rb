# frozen_string_literal: true

# THE #486 LANDMINE, MODELED (round-2 gate on #512, item 5).
#
# A token-authenticated API surface whose `current_duz` is (wrongly)
# session-derived — the hazardous implementation a sibling branch could ship.
# The attribution guard test proves the audit resolver keys on the
# AUTHENTICATING MECHANISM, so even this current_duz cannot make a
# bystanding browser session beat the token that actually authenticated the
# request. Exists only in the dummy host app; never shipped.
class SessionShadowedApiController < Lakeraven::EHR::ApplicationController
  def show
    render json: { ok: true }
  end

  private

  def fhir_resource_type = "Patient"

  # The bug being guarded against: "whatever is in the session".
  def current_duz = session[:duz]
end
