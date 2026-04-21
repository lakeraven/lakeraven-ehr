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
end
