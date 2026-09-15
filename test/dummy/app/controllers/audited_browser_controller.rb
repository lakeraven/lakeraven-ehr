# frozen_string_literal: true

# A representative AUDITED BROWSER SURFACE, for the "a refusal discloses
# nothing" contract.
#
# The FHIR controllers are `ActionController::API` and have no flash and no
# session, so nothing in-tree can express the leak that matters: a sibling PR
# refused an access with 503 and the chart's patient name still reached the
# browser, in the flash, carried in the session cookie the 503 response set.
# A clinician-facing surface is an `ActionController::Base` — so this one is
# too.
#
# It exists only in the dummy host app (never shipped) and does the three
# things an action can do to smuggle a fact past a discarded body: set a
# flash, set a response header, and redirect.
class AuditedBrowserController < ActionController::Base
  include Lakeraven::EHR::SmartAuthentication
  include Lakeraven::EHR::AuditableClinicalAccess

  before_action :authenticate_smart_token!

  # Synthetic name; the point of the test is that it must NOT appear anywhere
  # in a refused response.
  PATIENT_LABEL = "Anderson,Alice"

  def show
    flash[:notice] = "Opened chart for #{PATIENT_LABEL}"
    response.set_header("X-Patient-Name", PATIENT_LABEL)
    redirect_to "/patients/#{params[:dfn]}"
  end

  private

  def fhir_resource_type = "Patient"
end
