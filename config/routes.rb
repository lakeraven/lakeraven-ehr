# frozen_string_literal: true

Lakeraven::EHR::Engine.routes.draw do
  use_doorkeeper
  resources :patients, path: "Patient", only: %i[index show], param: :dfn
  resources :practitioners, path: "Practitioner", only: %i[index show], param: :ien
  resources :allergy_intolerances, path: "AllergyIntolerance", only: %i[index]
  resources :conditions, path: "Condition", only: %i[index]
  resources :medication_requests, path: "MedicationRequest", only: %i[index]
  resources :observations, path: "Observation", only: %i[index]
  resources :encounters, path: "Encounter", only: %i[index]
  resources :organizations, path: "Organization", only: %i[show], param: :ien
  resources :locations, path: "Location", only: %i[show], param: :ien
  resources :service_requests, path: "ServiceRequest", only: %i[index]
  resources :immunizations, path: "Immunization", only: %i[index]
  resources :procedures, path: "Procedure", only: %i[index]
  resources :coverage_eligibility_requests, path: "CoverageEligibilityRequest", only: %i[create]
  resources :measures, path: "Measure", only: %i[index]
  resources :measure_reports, path: "MeasureReport", only: %i[index]

  # Bulk export (FHIR $export)
  get "bulk-export-files/:export_id/:file_name", to: "bulk_exports#download", as: :bulk_export_download
  get "$export-status/:export_id", to: "bulk_exports#status", as: :bulk_export_status
  delete "$export-status/:export_id", to: "bulk_exports#cancel"
end
