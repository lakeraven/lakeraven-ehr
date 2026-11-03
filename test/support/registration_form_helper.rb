# frozen_string_literal: true

# Submits the new-patient form the way a browser does: open it, then post it with
# the one-time token it was issued (#721). A test that means to replay a form, or
# to post without one, posts directly.
module RegistrationFormHelper
  def registration_form_token
    get "/lakeraven-ehr/registration/patients/new"
    css_select("#registration-form input[name='submission_id']").first&.[]("value")
  end

  def submit_registration(entry)
    post "/lakeraven-ehr/registration/patients", params: { submission_id: registration_form_token, registration: entry }
  end
end
