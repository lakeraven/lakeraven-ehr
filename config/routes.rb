# frozen_string_literal: true

Lakeraven::EHR::Engine.routes.draw do
  resources :patients, path: "Patient", only: [ :index, :show ], param: :dfn
end
