# frozen_string_literal: true

Lakeraven::EHR::Engine.routes.draw do
  use_doorkeeper
  resources :patients, path: "Patient", only: [ :index, :show ], param: :dfn
  resources :practitioners, path: "Practitioner", only: [ :index, :show ], param: :ien
end
