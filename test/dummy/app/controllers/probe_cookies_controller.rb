# frozen_string_literal: true

# EVERY cookie-write path an action has, adopted from the round-2 gate's
# probe: proves the S8 rollback's completeness across plain/signed/encrypted/
# permanent jars, pending deletes, raw Set-Cookie writes, and the session.
# Exists only in the dummy host app; never shipped.
class ProbeCookiesController < ActionController::Base
  include Lakeraven::EHR::SmartAuthentication
  include Lakeraven::EHR::AuditableClinicalAccess

  before_action :authenticate_smart_token!

  LABEL = "Anderson,Alice"

  def show
    cookies[:plain_patient] = LABEL
    cookies.signed[:signed_patient] = LABEL
    cookies.encrypted[:encrypted_patient] = LABEL
    cookies.permanent[:permanent_patient] = LABEL
    cookies.delete(:preexisting_cookie)
    # A direct Set-Cookie header, bypassing the jar entirely.
    response.set_header("Set-Cookie", "raw_header_patient=#{ERB::Util.url_encode(LABEL)}")
    # OVERWRITE a header that existed before the action (a default security
    # header): a name-only snapshot misses this — the name survives the
    # delete-by-difference and carries the overwritten PHI value out.
    response.set_header("X-Frame-Options", LABEL)
    # response.set_cookie writes the header directly too.
    response.set_cookie(:response_api_patient, value: LABEL, path: "/")
    session[:probe_patient] = LABEL
    render plain: "ok"
  end

  private

  def fhir_resource_type = "Patient"
end
