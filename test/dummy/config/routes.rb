# frozen_string_literal: true

Rails.application.routes.draw do
  mount Lakeraven::EHR::Engine => "/lakeraven-ehr"

  # Demo convenience: expose the engine's read-only chart at the host root
  # so the partner demo URL is simply /patients/:dfn (issue #452).
  get "patients/:dfn(.:format)", to: "lakeraven/ehr/charts#show", constraints: { dfn: /\d+/ }

  # Test-only: a representative audited writer, for the fail-closed audit
  # contract. Never routed outside the test environment.
  post "audited_writer" => "audited_writer#create" if Rails.env.test?

  # Test-only: a representative audited BROWSER surface (flash + session +
  # cookie + redirect), for the "a refusal discloses nothing" contract.
  get "audited_browser/:dfn" => "audited_browser#show", constraints: { dfn: /\d+/ } if Rails.env.test?

  # Test-only: representative pages inheriting the engine WebController, so
  # the refusal-audit contract is proven across SEVERAL inheriting
  # controllers rather than the one engine page that exists today.
  if Rails.env.test?
    get "staff" => "staff_pages#index"
    get "worklists" => "worklist_pages#index"
  end
end
