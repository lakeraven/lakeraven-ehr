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

  # FHIR CapabilityStatement (#574). Every FHIR type routed below is declared
  # in FHIR::CapabilityStatement, and a route with no controller action
  # behind it is not routed: Medication, DiagnosticReport and CarePlan were,
  # and Encounter's show, and each raised instead of answering.
  get "metadata", to: "capability_statements#show"

  # Doorkeeper models (Application, AccessToken) are used directly;
  # routes are NOT mounted here because the engine provides its own
  # BackendServicesController for OAuth token issuance.
  resources :patients, path: "Patient", only: %i[index show create], param: :dfn
  resources :practitioners, path: "Practitioner", only: %i[index show], param: :ien
  resources :allergy_intolerances, path: "AllergyIntolerance", only: %i[index show]
  resources :conditions, path: "Condition", only: %i[index show]
  resources :medication_requests, path: "MedicationRequest", only: %i[index show]
  resources :observations, path: "Observation", only: %i[index show]
  resources :encounters, path: "Encounter", only: %i[index]
  resources :organizations, path: "Organization", only: %i[show], param: :ien
  resources :locations, path: "Location", only: %i[show], param: :ien
  resources :service_requests, path: "ServiceRequest", only: %i[index]
  resources :immunizations, path: "Immunization", only: %i[index]
  resources :procedures, path: "Procedure", only: %i[index]
  resources :coverage_eligibility_requests, path: "CoverageEligibilityRequest", only: %i[create]
  resources :measures, path: "Measure", only: %i[index]
  resources :measure_reports, path: "MeasureReport", only: %i[index]
  resources :consents, path: "Consent", only: %i[index show]
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

  # SMART discovery + EHR Launch
  get ".well-known/smart-configuration", to: "smart_configuration#show"
  get "smart/launch", to: "smart_launch#show"

  # Backend Services JWT auth
  post "oauth/token", to: "backend_services#token"

  # Measure $import
  post "Measure/$import", to: "measures#import"

  # Web UI — login, dashboard (accessibility / ops surface)
  get "login" => "sessions#new", as: :login
  # Real VistA sign-on (#332): validates access/verify against RPMS and mints a
  # SMART session token. Open in all environments (replaces the #401 test-only
  # canned login).
  post "login" => "sessions#create"
  delete "logout" => "sessions#destroy", as: :logout
  get "dashboard" => "dashboards#show", as: :dashboard

  # Test-only: seed the browser session (DUZ, user type, security keys, and
  # the session-bound SMART token) without the RPMS sign-on flow. The
  # controller refuses to exist outside the test environment; the route guard
  # is the second belt.
  post "test_session" => "test_sessions#create" if Rails.env.test?
end
