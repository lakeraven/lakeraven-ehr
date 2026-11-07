# frozen_string_literal: true

Rails.application.routes.draw do
  mount Lakeraven::EHR::Engine => "/lakeraven-ehr"

  # The engine is mounted under /lakeraven-ehr, so the bare host and /login would be 404s.
  # Both go to the engine's sign-in page. 302, not 301: a homepage at / may replace this.
  root to: redirect("/lakeraven-ehr/login", status: 302)
  get "login", to: redirect("/lakeraven-ehr/login", status: 302)

  # Health check for the container and its load balancer: 200 once the app boots.
  get "up" => "rails/health#show", as: :rails_health_check

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

  # Test-only: the #486 landmine modeled — a token-authenticated API surface
  # with a session-derived current_duz, for the mechanism-wins guard test.
  get "session_shadowed_api/:id" => "session_shadowed_api#show" if Rails.env.test?

  # Test-only: every cookie-write path an action has (plain/signed/encrypted/
  # permanent jars, pending deletes, raw Set-Cookie, response.set_cookie,
  # session), for the S8 rollback-completeness contract. Adopted from the
  # round-2 gate's probe.
  get "probe_cookies/:dfn" => "probe_cookies#show", constraints: { dfn: /\d+/ } if Rails.env.test?

  # Test-only probes for the session-write landing contract (#486/#491): one
  # route where forgery protection is genuinely enforced, one where it is
  # skipped. Never routed outside the test environment.
  if Rails.env.test?
    post "csrf_probe" => "csrf_probe#create"
    post "csrf_disabled_probe" => "csrf_disabled_probe#create"
    # F1 attack configurations: non-rejecting strategies and a per-action skip.
    post "null_session_probe" => "null_session_probe#create"
    post "reset_session_probe" => "reset_session_probe#create"
    post "conditional_skip_probe" => "conditional_skip_probe#create"
  end

  # Test-only: host routes that point STRAIGHT at the engine's governed
  # controllers, bypassing the engine's routing constraints (#522 gap B). A
  # host app can draw exactly these, so a closed disclosure surface must
  # still answer 404 here — before authentication, before the rate limiter
  # and before any broker call. Param names match the engine's own routes
  # (config/routes.rb) and the controllers' params[...] reads.
  if Rails.env.test?
    get "host_fhir/Patient/:dfn", to: "lakeraven/ehr/patients#show"
    get "host_fhir/Condition", to: "lakeraven/ehr/conditions#index"
    post "host_exports", to: "lakeraven/ehr/exports#create"
    get "host_exports/:export_id/files/:file_name", to: "lakeraven/ehr/export_files#show",
      format: false, constraints: { file_name: %r{[^/]+} }
    post "host_transitions_of_care", to: "lakeraven/ehr/transitions_of_care#create"
  end
end
