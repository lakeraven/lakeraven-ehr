# frozen_string_literal: true

Lakeraven::EHR::Engine.routes.draw do
  # Read-only demo patient chart (issue #452). SMART bearer auth enforced;
  # dev-only synthetic-demo bypass lives in ChartsController#demo_bypass?.
  # Content-negotiated: HTML for browsers, FHIR R4 Bundle for `.json`
  # (or Accept: application/fhir+json / ?_format=json). The `.:format`
  # segment is optional so `patients/1` and `patients/1.json` both resolve;
  # dfn is constrained to digits so the extension isn't swallowed.
  # RESTful path: the chart is the human-facing representation of a patient,
  # so it lives at /patients/:dfn (the FHIR API keeps /Patient per convention;
  # that resource also owns the patient_path helper, hence :patient_chart).
  get "patients/:dfn(.:format)", to: "charts#show", as: :patient_chart, constraints: { dfn: /\d+/ }

  # Doorkeeper models (Application, AccessToken) are used directly;
  # routes are NOT mounted here because the engine provides its own
  # BackendServicesController for OAuth token issuance.
  resources :patients, path: "Patient", only: %i[index show create], param: :dfn
  resources :practitioners, path: "Practitioner", only: %i[index show], param: :ien
  resources :allergy_intolerances, path: "AllergyIntolerance", only: %i[index show]
  resources :conditions, path: "Condition", only: %i[index show]
  resources :medication_requests, path: "MedicationRequest", only: %i[index show]
  resources :observations, path: "Observation", only: %i[index show]
  # Provenance — office-measured vs remote/historical capture (Vardana
  # item 10). Ids are prov-{measurement-ien}; the constraint keeps any
  # dotted id portion out of the :format segment.
  resources :provenances, path: "Provenance", only: %i[index show], constraints: { id: /[^\/]+/ }
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
    resources :files, only: [ :show ], controller: "export_files", param: :file_name
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
  # Test-only canned-credential login (#401 interim); the real VistA sign-on
  # gateway (#332) will replace this and open the route in all environments.
  if Rails.env.test?
    post "login" => "sessions#create"
  end
  delete "logout" => "sessions#destroy", as: :logout
  get "dashboard" => "dashboards#show", as: :dashboard
end
