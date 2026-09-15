# frozen_string_literal: true

Rails.application.routes.draw do
  mount Lakeraven::EHR::Engine => "/lakeraven-ehr"

  # Demo convenience: expose the engine's read-only chart at the host root
  # so the partner demo URL is simply /patients/:dfn (issue #452).
  get "patients/:dfn(.:format)", to: "lakeraven/ehr/charts#show", constraints: { dfn: /\d+/ }

  # Test-only probes for the session-write landing contract (#486/#491): one
  # route where forgery protection is genuinely enforced, one where it is
  # skipped. Never routed outside the test environment.
  if Rails.env.test?
    post "csrf_probe" => "csrf_probe#create"
    post "csrf_disabled_probe" => "csrf_disabled_probe#create"
  end
end
