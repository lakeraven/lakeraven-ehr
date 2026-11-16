# frozen_string_literal: true

Lakeraven::EHR::Engine.routes.draw do
  # Read-only demo patient chart (issue #452). SMART bearer auth enforced;
  # dev-only synthetic-demo bypass lives in ChartsController#demo_bypass?.
  # Content-negotiated: HTML for browsers, FHIR R4 Bundle for `.json`
  # (or Accept: application/fhir+json / ?_format=json). The `.:format`
  # segment is optional so `patients/1` and `patients/1.json` both resolve.
  # dfn is not limited to digits (#467): a malformed identifier has to reach
  # ChartsController's format gate. The segment still excludes "." (and the
  # other route separators) so the extension is not swallowed — `patients/1.json`
  # is dfn "1" with format json. Sibling patient routes keep their digit
  # constraints.
  # RESTful path: the chart is the human-facing representation of a patient,
  # so it lives at /patients/:dfn (the FHIR API keeps /Patient per convention;
  # that resource also owns the patient_path helper, hence :patient_chart).
  get "patients/:dfn(.:format)", to: "charts#show", as: :patient_chart, constraints: { dfn: %r{[^/.?]+} }
  # Demo-only clickable walk-in visit (the UI counterpart of
  # features/encounter/demo_visit.feature). Gated to dev + CHART_DEMO_OPEN +
  # SPIKE_MOCK_RPC in the controller; 404s everywhere else.
  get  "patients/:dfn/visit",        to: "demo_visits#show",   as: :patient_visit, constraints: { dfn: /\d+/ }
  post "patients/:dfn/visit/vitals", to: "demo_visits#vitals", constraints: { dfn: /\d+/ }
  post "patients/:dfn/visit/pov",    to: "demo_visits#pov",    constraints: { dfn: /\d+/ }
  post "patients/:dfn/visit/note",   to: "demo_visits#note",   constraints: { dfn: /\d+/ }
  post "patients/:dfn/visit/close",  to: "demo_visits#close",  constraints: { dfn: /\d+/ }
  post "patients/:dfn/visit/reset",  to: "demo_visits#reset",  constraints: { dfn: /\d+/ }
  # RESTful aliases: new visit form + saved-visit show page (HTML or FHIR .json)
  get  "patients/:dfn/visits/new",           to: "demo_visits#new",     as: :new_patient_visit, constraints: { dfn: /\d+/ }
  get  "patients/:dfn/visits/:id(.:format)", to: "demo_visits#summary", as: :patient_visit_summary, constraints: { dfn: /\d+/, id: /\d+/ }

  # Opening a patient's record in the clinician SESSION (the web surface's
  # counterpart of a patient-scoped token's compartment binding). A deliberate,
  # audited POST — everything session-authenticated that reads a patient's
  # clinical data requires it.
  post "patients/:dfn/context", to: "patient_contexts#create", as: :patient_context, constraints: { dfn: /\d+/ }
  # Closing the session's open record. Fixed destination, so this cannot be
  # turned into an open redirect. Its own controller: PatientContextsController's
  # before_actions authorize *opening* a record and must not run on a clear.
  delete "patient_context", to: "active_patient_contexts#destroy", as: :active_patient_context

  # Scored behavioural-health instruments (PHQ-9 / GAD-7, issue #474).
  # Server-rendered, no JavaScript. `new` carries the instrument key as a
  # query param (?instrument=phq-9); the :id constraint keeps the digits-only
  # show route from swallowing it.
  get  "patients/:dfn/screenings",     to: "screenings#index",  as: :patient_screenings, constraints: { dfn: /\d+/ }
  post "patients/:dfn/screenings",     to: "screenings#create", constraints: { dfn: /\d+/ }
  get  "patients/:dfn/screenings/new", to: "screenings#new",    as: :new_patient_screening, constraints: { dfn: /\d+/ }
  get  "patients/:dfn/screenings/:id", to: "screenings#show",   as: :patient_screening, constraints: { dfn: /\d+/, id: /\d+/ }

  # Chart allergy entry (#644). Writes are POST only — there is no GET
  # that records an allergy or no-known-allergies.
  get  "patients/:dfn/allergies/new", to: "allergies#new", as: :new_patient_allergy,
    constraints: { dfn: /\d+/ }
  post "patients/:dfn/allergies", to: "allergies#create", as: :patient_allergies,
    constraints: { dfn: /\d+/ }
  post "patients/:dfn/allergies/no_known_allergies", to: "allergies#no_known_allergies",
    as: :patient_no_known_allergies, constraints: { dfn: /\d+/ }

  # A progress note written and signed from the chart (#1001). The note is
  # created, written and signed by the POST only.
  get  "patients/:dfn/notes/new", to: "progress_notes#new", as: :new_patient_progress_note,
    constraints: { dfn: /\d+/ }
  post "patients/:dfn/notes", to: "progress_notes#create", as: :patient_progress_notes,
    constraints: { dfn: /\d+/ }

  # In-clinic consent (#793). A signature is immutable, so there is no
  # update or delete route. Revocation is a new row. `new` and `handover`
  # are declared before any `:id` segment.
  get  "patients/:dfn/consents", to: "consents#index", as: :patient_consents,
    constraints: { dfn: /\d+/ }
  get  "patients/:dfn/consents/new", to: "consents#new", as: :new_patient_consent,
    constraints: { dfn: /\d+/ }
  post "patients/:dfn/consents/handover", to: "consents#handover", as: :patient_consent_handover,
    constraints: { dfn: /\d+/ }
  post "patients/:dfn/consents/:id/revocation", to: "consents#revocation",
    as: :patient_consent_revocation, constraints: { dfn: /\d+/, id: /\d+/ }
  get  "consent_kiosk", to: "consent_kiosk#show", as: :consent_kiosk
  post "consent_kiosk", to: "consent_kiosk#create"
  post "consent_kiosk/unlock", to: "consent_kiosk#unlock", as: :consent_kiosk_unlock

  # FHIR CapabilityStatement (#574). Every FHIR type routed below is declared
  # in FHIR::CapabilityStatement, and a route with no controller action
  # behind it is not routed: Medication, DiagnosticReport and CarePlan were,
  # and Encounter's show, and each raised instead of answering.
  get "metadata", to: "capability_statements#show"

  # Doorkeeper models (Application, AccessToken) are used directly;
  # routes are NOT mounted here because the engine provides its own
  # BackendServicesController for OAuth token issuance.
  # No create: registration is AG's, on the front desk's screens (#542).
  resources :patients, path: "Patient", only: %i[index show], param: :dfn
  resources :practitioners, path: "Practitioner", only: %i[index show], param: :ien
  resources :allergy_intolerances, path: "AllergyIntolerance", only: %i[index show]
  resources :conditions, path: "Condition", only: %i[index show]
  resources :medication_requests, path: "MedicationRequest", only: %i[index show]
  resources :observations, path: "Observation", only: %i[index show]
  resources :encounters, path: "Encounter", only: %i[index show]
  resources :organizations, path: "Organization", only: %i[show], param: :ien
  resources :locations, path: "Location", only: %i[index show], param: :ien
  resources :service_requests, path: "ServiceRequest", only: %i[index show]
  resources :immunizations, path: "Immunization", only: %i[index show]
  resources :procedures, path: "Procedure", only: %i[index show]
  resources :coverage_eligibility_requests, path: "CoverageEligibilityRequest", only: %i[create]
  resources :measures, path: "Measure", only: %i[index]
  resources :measure_reports, path: "MeasureReport", only: %i[index]
  resources :audit_events, path: "AuditEvent", only: %i[index show]
  resources :value_sets, path: "ValueSet", only: %i[index show] do
    member do
      get "$expand", action: :expand
    end
  end

  # Transitions of Care — ONC §170.315(b)(1)
  resources :transitions_of_care, only: [ :create ]
  resources :ccda_imports, only: [ :create ]

  # Exports — ONC §170.315(b)(10) + (g)(10)
  resources :exports, only: [ :create, :show, :destroy ] do
    # The documented file URL ends in "patient.ndjson". `format: false`
    # drops the format suffix; the file_name constraint is what lets the
    # dot through, because "." is still a segment separator without it.
    resources :files, only: [ :show ], controller: "export_files", param: :file_name,
      format: false, file_name: %r{[^/]+}
  end

  # SMART discovery + EHR Launch. smart/launch is the EHR side: a signed-in
  # user opens a patient in a registered app, which is sent to the app's
  # launch URI with `iss` and `launch` (#839). smart/style is the
  # smart_style_url a launched token response names.
  get ".well-known/smart-configuration", to: "smart_configuration#show"
  get "smart/launch", to: "smart_launch#show", as: :smart_launch
  post "smart/launch", to: "smart_launch#create"
  get "smart/style", to: "smart_styles#show", as: :smart_style, defaults: { format: :json }

  # SMART App Launch authorization code flow (#839). The user signs in with
  # their own RPMS codes and approves; GET and POST are both served.
  get "oauth/authorize", to: "smart_authorizations#new", as: :smart_authorization
  post "oauth/authorize", to: "smart_authorizations#new"
  get "oauth/authorize/approval", to: "smart_authorizations#show", as: :smart_authorization_approval
  post "oauth/authorize/approval", to: "smart_authorizations#decide"
  get "oauth/authorize/patient", to: "smart_authorizations#patient", as: :smart_authorization_patient
  post "oauth/authorize/patient", to: "smart_authorizations#choose_patient"

  # One token endpoint, two grants: the authorization code from a launch, and
  # Backend Services client_credentials (JWT auth) for everything else.
  post "oauth/token", to: "smart_tokens#create",
    constraints: ->(req) { req.request_parameters["grant_type"] == "authorization_code" }
  post "oauth/token", to: "backend_services#token"

  # Measure $import
  post "Measure/$import", to: "measures#import"

  # Web UI — login, dashboard (accessibility / ops surface)
  get "login" => "sessions#new", as: :login
  # Real VistA sign-on (#332): validates access/verify against RPMS and mints a
  # SMART session token. Open in all environments (replaces the #401 test-only
  # canned login).
  post "login" => "sessions#create"
  # The public demo's terms (#952): accepting them lets the sign-in form show.
  # Not found unless Configuration#demo_mode is on.
  post "login/demo_terms" => "sessions#accept_demo_terms", as: :accept_demo_terms
  delete "logout" => "sessions#destroy", as: :logout
  get "dashboard" => "dashboards#show", as: :dashboard
  # The signed-in user's RPMS notifications (rpms-ux S-SGN-02.1, #874).
  get "notifications" => "notifications#index", as: :notifications
  # Remove one, or forward one to a colleague (rpms-ux S-SGN-02.2 to 02.4). An
  # alert ID holds commas, semicolons and a dot ("OR,3,19;4;3261104.175206"),
  # so the segment takes anything but a slash, and no format is read from it.
  scope "notifications/:alert_id", constraints: { alert_id: %r{[^/]+} }, format: false do
    delete "" => "notifications#destroy", as: :notification
    get "forward" => "notification_forwards#new", as: :new_notification_forward
    post "forward/find" => "notification_forwards#find", as: :find_notification_forward
    post "forward" => "notification_forwards#create", as: :notification_forward
  end

  # The referrals pending at the facility, for a user who works referrals (#873).
  get "referrals/pending", to: "pending_referrals#index", as: :pending_referrals

  # The patient bar's search and recent patients (rpms-ux S-CHT-01). A search
  # names a patient, so it is posted, never carried in a URL (#722).
  get "chart_search", to: "chart_searches#show", as: :chart_search
  post "chart_search", to: "chart_searches#create"
  # The tablet lock covers this search path as well as chart_search. Same
  # action, same gate: a POST, so the query is not carried in the URL.
  post "patients/search", to: "chart_searches#create"

  # The front desk finds a patient (rpms-ux S-REG-01) and registers a new one (S-REG-02).
  namespace :registration do
    get "patients", to: "patients#index", as: :patients
    # A search names a patient (an SSN, a name, a date of birth), so it is posted,
    # never carried in a URL, browser history or a log line (#722).
    post "patients/search", to: "patients#index", as: :search_patients
    get "patients/new", to: "patients#new", as: :new_patient
    # The tribe and community look-ups post the form back, with its demographics (#722).
    post "patients/new", to: "patients#new"
    post "patients", to: "patients#create"
    post "patients/confirm", to: "patients#confirm", as: :confirm_patient
    get "patients/:dfn", to: "patients#show", as: :patient, constraints: { dfn: /\d+/ }
    # Keeping a registered patient current (S-REG-20, S-REG-21), a section at a time.
    get "patients/:dfn/demographics/edit", to: "demographics#edit", as: :edit_patient_demographics, constraints: { dfn: /\d+/ }
    patch "patients/:dfn/demographics", to: "demographics#update", as: :patient_demographics, constraints: { dfn: /\d+/ }
    get "patients/:dfn/address/edit", to: "addresses#edit", as: :edit_patient_address, constraints: { dfn: /\d+/ }
    patch "patients/:dfn/address", to: "addresses#update", as: :patient_address, constraints: { dfn: /\d+/ }
    # The emergency contact and next of kin (S-REG-08), shown on the patient's page. A look-up posts the form
    # back to edit, so what the clerk typed never rides in a URL (#722).
    scope "patients/:dfn", constraints: { dfn: /\d+/ } do
      get "contacts/:kind/edit", to: "contacts#edit", as: :edit_patient_contact
      post "contacts/:kind/edit", to: "contacts#edit"
      post "contacts/:kind", to: "contacts#update", as: :patient_contact
      # The migrant, homeless and internet questions (S-REG-11, S-REG-22.5, S-REG-31.3):
      # each answer a new dated entry.
      get "social_status/edit", to: "social_statuses#edit", as: :edit_patient_social_status
      post "social_status", to: "social_statuses#update", as: :patient_social_status

      # The patient's languages (S-REG-10): each save a new dated entry.
      get "languages/edit", to: "languages#edit", as: :edit_patient_languages
      post "languages/edit", to: "languages#edit"
      post "languages", to: "languages#update", as: :patient_languages
      # The name the patient goes by (S-REG-12.1): PREFERRED NAME, IHS PATIENT (9000001) 9001.
      get "preferred_name/edit", to: "preferred_names#edit", as: :edit_patient_preferred_name
      post "preferred_name", to: "preferred_names#update", as: :patient_preferred_name
      # Race and ethnicity with how each was collected (S-REG-20.2): PATIENT (2.02, 2.06).
      get "race_ethnicity/edit", to: "race_ethnicities#edit", as: :edit_patient_race_ethnicity
      post "race_ethnicity", to: "race_ethnicities#update", as: :patient_race_ethnicity
      # The other names the patient has used (S-REG-12): ALIAS, PATIENT (2.01).
      # The other tribes and eligibility modifiers (S-REG-07.2, S-REG-07.3).
      get "other_tribes", to: "other_tribes#index", as: :patient_other_tribes
      post "other_tribes", to: "other_tribes#create"
      post "other_tribes/:ien/remove", to: "other_tribes#destroy", as: :remove_patient_other_tribe, constraints: { ien: /\d+/ }
      get "eligibility_modifiers", to: "eligibility_modifiers#index", as: :patient_eligibility_modifiers
      post "eligibility_modifiers", to: "eligibility_modifiers#create"
      post "eligibility_modifiers/:ien/remove", to: "eligibility_modifiers#destroy", as: :remove_patient_eligibility_modifier, constraints: { ien: /\d+/ }
      get "other_names", to: "other_names#index", as: :patient_other_names
      post "other_names", to: "other_names#create"
      post "other_names/:ien/remove", to: "other_names#destroy", as: :remove_patient_other_name, constraints: { ien: /\d+/ }
    end
    # Tribe, blood quantum and eligibility (S-REG-07). Find tribe posts the form back (#722).
    get "patients/:dfn/eligibility/edit", to: "eligibilities#edit", as: :edit_patient_eligibility, constraints: { dfn: /\d+/ }
    patch "patients/:dfn/eligibility", to: "eligibilities#update", as: :patient_eligibility, constraints: { dfn: /\d+/ }
    # The patient's Medicaid, Medicare and private insurance (S-REG-03). The
    # state and insurer look-ups post the form back, so a member number never
    # travels in a URL (#722).
    get "patients/:dfn/coverage", to: "coverages#index", as: :patient_coverage, constraints: { dfn: /\d+/ }
    # The patient's applications for coverage (S-REG-03.3 to 03.5): PATIENT APPLICATIONS (9000045).
    get "patients/:dfn/applications/new", to: "applications#new", as: :new_patient_application, constraints: { dfn: /\d+/ }
    post "patients/:dfn/applications", to: "applications#create", as: :patient_applications, constraints: { dfn: /\d+/ }
    post "patients/:dfn/applications/:ien/status", to: "applications#update", as: :patient_application_status,
                                                    constraints: { dfn: /\d+/, ien: /\d+/ }
    get "patients/:dfn/coverage/new", to: "coverages#new", as: :new_patient_coverage, constraints: { dfn: /\d+/ }
    post "patients/:dfn/coverage/new", to: "coverages#new", constraints: { dfn: /\d+/ }
    post "patients/:dfn/coverage", to: "coverages#create", constraints: { dfn: /\d+/ }
    # The registration tables a site keeps itself (BPRM Settings > Table Maintenance).
    get "setup", to: "setup/tables#index", as: :setup
    # Eligibility modifiers for a name change, a legal document or legal sex (lakeraven-ehr#982).
    get "setup/eligibility_modifiers", to: "setup/eligibility_modifiers#index", as: :setup_eligibility_modifiers
    get "setup/eligibility_modifiers/new", to: "setup/eligibility_modifiers#new", as: :new_setup_eligibility_modifier
    post "setup/eligibility_modifiers", to: "setup/eligibility_modifiers#create"
    get "setup/eligibility_modifiers/:ien/edit", to: "setup/eligibility_modifiers#edit", as: :edit_setup_eligibility_modifier,
                                                  constraints: { ien: /\d+/ }
    post "setup/eligibility_modifiers/:ien", to: "setup/eligibility_modifiers#update", as: :setup_eligibility_modifier,
                                              constraints: { ien: /\d+/ }
    # The site's local patient record flags (lakeraven-ehr#983).
    get "setup/local_flags", to: "setup/local_flags#index", as: :setup_local_flags
    get "setup/local_flags/new", to: "setup/local_flags#new", as: :new_setup_local_flag
    post "setup/local_flags", to: "setup/local_flags#create"
    get "setup/local_flags/:ien/edit", to: "setup/local_flags#edit", as: :edit_setup_local_flag, constraints: { ien: /\d+/ }
    post "setup/local_flags/:ien", to: "setup/local_flags#update", as: :setup_local_flag, constraints: { ien: /\d+/ }
  end

  # Scheduling (rpms-ux W02): a clinic resource's day, booking into it (S-SCH-01)
  # cancelling (S-SCH-02) and checking in (S-SCH-03).
  namespace :scheduling do
    get "/", to: "clinics#index", as: :home
    get "clinics/:id", to: "clinics#show", as: :clinic, constraints: { id: /\d+/ }
    get "clinics/:id/week", to: "clinics#week", as: :clinic_week, constraints: { id: /\d+/ }
    # A clinic's wait list (S-SCH-10).
    scope "clinics/:resource_id/wait_list", constraints: { resource_id: /\d+/ } do
      get "/", to: "wait_lists#index", as: :clinic_wait_list
      post "/", to: "wait_lists#create"
      get "new", to: "wait_lists#new", as: :new_clinic_wait_list
      scope ":entry_id", constraints: { entry_id: /\d+/ } do
        get "edit", to: "wait_lists#edit", as: :edit_clinic_wait_list
        post "/", to: "wait_lists#update", as: :clinic_wait_list_entry
        get "removal", to: "wait_lists#removal", as: :clinic_wait_list_removal
        post "removal", to: "wait_lists#remove"
        get "booking", to: "wait_lists#booking", as: :clinic_wait_list_booking
        post "booking", to: "wait_lists#book"
      end
    end
    # The appointments across the scheduler's clinics (S-SCH-05.5).
    get "appointments", to: "appointment_lists#index", as: :appointment_list
    # The appointments needing action in the scheduler's clinics (S-SCH-13.5, #875).
    get "needing_action", to: "needing_action#index", as: :needing_action
    # Table maintenance (S-SCH-17, S-SCH-18): access types (SDZSUP) and resource groups.
    get "access_types", to: "access_types#index", as: :access_types
    get "access_types/new", to: "access_types#new", as: :new_access_type
    post "access_types", to: "access_types#create"
    get "access_types/:id/edit", to: "access_types#edit", as: :edit_access_type, constraints: { id: /\d+/ }
    post "access_types/:id", to: "access_types#update", as: :access_type, constraints: { id: /\d+/ }
    get "resource_groups", to: "resource_groups#index", as: :resource_groups
    get "resource_groups/new", to: "resource_groups#new", as: :new_resource_group
    post "resource_groups", to: "resource_groups#create"
    get "resource_groups/:id", to: "resource_groups#show", as: :resource_group, constraints: { id: /\d+/ }
    post "resource_groups/:id/members", to: "resource_groups#add_member", as: :resource_group_members, constraints: { id: /\d+/ }
    post "resource_groups/:id/members/:item_id/remove", to: "resource_groups#remove_member", as: :remove_resource_group_member,
                                                         constraints: { id: /\d+/, item_id: /\d+/ }
    get "clinics/:id/open_times", to: "open_times#index", as: :clinic_open_times, constraints: { id: /\d+/ }
    # A clinic's scheduling settings and letters (S-SCH-15); changing them takes SDZSUP.
    get "clinics/:resource_id/settings", to: "clinic_settings#show", as: :clinic_settings, constraints: { resource_id: /\d+/ }
    get "clinics/:resource_id/settings/edit", to: "clinic_settings#edit", as: :edit_clinic_settings, constraints: { resource_id: /\d+/ }
    post "clinics/:resource_id/settings", to: "clinic_settings#update", constraints: { resource_id: /\d+/ }
    get "clinics/:resource_id/hours/new", to: "hours#new", as: :new_clinic_hours, constraints: { resource_id: /\d+/ }
    post "clinics/:resource_id/hours", to: "hours#create", as: :clinic_hours, constraints: { resource_id: /\d+/ }
    get "patients/:dfn/appointments", to: "patient_appointments#index", as: :patient_appointments, constraints: { dfn: /\d+/ }
    get "clinics/:resource_id/appointments/new", to: "appointments#new", as: :new_clinic_appointment, constraints: { resource_id: /\d+/ }
    post "clinics/:resource_id/appointments", to: "appointments#create", as: :clinic_appointments, constraints: { resource_id: /\d+/ }
    # Registering a caller with no chart while booking them (rpms-ux S-REG-05). Posted: the form names the caller (#722).
    get "clinics/:resource_id/registrations/new", to: "quick_registrations#new", as: :new_clinic_registration, constraints: { resource_id: /\d+/ }
    post "clinics/:resource_id/registrations", to: "quick_registrations#create", as: :clinic_registrations, constraints: { resource_id: /\d+/ }
    get "clinics/:resource_id/appointments/:appointment_id/cancel", to: "cancellations#new", as: :cancel_clinic_appointment, constraints: { resource_id: /\d+/, appointment_id: /\d+/ }
    post "clinics/:resource_id/appointments/:appointment_id/cancel", to: "cancellations#create", constraints: { resource_id: /\d+/, appointment_id: /\d+/ }
    get "clinics/:resource_id/appointments/:appointment_id/checkin", to: "checkins#new", as: :checkin_clinic_appointment, constraints: { resource_id: /\d+/, appointment_id: /\d+/ }
    post "clinics/:resource_id/appointments/:appointment_id/checkin", to: "checkins#create", constraints: { resource_id: /\d+/, appointment_id: /\d+/ }
    get "clinics/:resource_id/appointments/:appointment_id/reschedule", to: "reschedules#new", as: :reschedule_clinic_appointment, constraints: { resource_id: /\d+/, appointment_id: /\d+/ }
    post "clinics/:resource_id/appointments/:appointment_id/reschedule", to: "reschedules#create", constraints: { resource_id: /\d+/, appointment_id: /\d+/ }
    get "clinics/:resource_id/appointments/:appointment_id/details", to: "appointment_details#new", as: :appointment_details, constraints: { resource_id: /\d+/, appointment_id: /\d+/ }
    post "clinics/:resource_id/appointments/:appointment_id/details", to: "appointment_details#create", constraints: { resource_id: /\d+/, appointment_id: /\d+/ }
    get "clinics/:resource_id/walk_ins/new", to: "walk_ins#new", as: :new_clinic_walk_in, constraints: { resource_id: /\d+/ }
    post "clinics/:resource_id/walk_ins/find", to: "walk_ins#find", as: :find_clinic_walk_in, constraints: { resource_id: /\d+/ }
    post "clinics/:resource_id/walk_ins", to: "walk_ins#create", as: :clinic_walk_ins, constraints: { resource_id: /\d+/ }
    # After check-in (S-SCH-03.9, S-SCH-07, S-SCH-08): undo it, check out and undo that, no-show and undo that.
    scope "clinics/:resource_id/appointments/:appointment_id", constraints: { resource_id: /\d+/, appointment_id: /\d+/ } do
      post "checkin/undo", to: "checkins#undo", as: :undo_checkin_clinic_appointment
      get "checkout", to: "checkouts#new", as: :checkout_clinic_appointment
      post "checkout", to: "checkouts#create"
      post "checkout/undo", to: "checkouts#undo", as: :undo_checkout_clinic_appointment
      post "no_show", to: "no_shows#create", as: :no_show_clinic_appointment
      post "no_show/undo", to: "no_shows#undo", as: :undo_no_show_clinic_appointment
    end
  end

  # Test-only: seed the browser session (DUZ, user type, security keys, and
  # the session-bound SMART token) without the RPMS sign-on flow. The
  # controller refuses to exist outside the test environment; the route guard
  # is the second belt.
  post "test_session" => "test_sessions#create" if Rails.env.test?
end
