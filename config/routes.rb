# frozen_string_literal: true

Lakeraven::EHR::Engine.routes.draw do
  use_doorkeeper
  resources :patients, path: "Patient", only: %i[index show], param: :dfn
  resources :practitioners, path: "Practitioner", only: %i[index show], param: :ien
end
