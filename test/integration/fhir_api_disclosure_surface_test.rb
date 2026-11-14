# frozen_string_literal: true

require "test_helper"

# The FHIR REST API is the :fhir_api disclosure surface (#970): closed unless
# the host opens it by name. App code this spec expects:
#
#   DisclosureSurfaces::RouteConstraint.new(:fhir_api)  # ArgumentError on an unknown name
#     #matches?(request)  -> DisclosureSurfaces.open?(:fhir_api); the engine draws its FHIR routes inside it
#   SmartAuthentication.bearer_authorization?(request)  # true for "Bearer <token>", any case
#   DisclosureSurfaces.ungated_routes(route_set, allow: UNGOVERNED_API_ROUTES.keys) -> [String]
#     "controller#action" (controller as in route.defaults, e.g. "lakeraven/ehr/patients#show") for every
#     FHIR-API route of +route_set+ (controller < ApplicationController, or first path segment starts with
#     an uppercase letter or "$") whose controller has no unconditional disclosure_surface rule covering
#     the action, and which is not in +allow+.
#   DisclosureSurfaces::UNGOVERNED_API_ROUTES  # frozen Hash: "controller#action" => one-line reason
#
# An unconditional rule is a disclosure_surface_rules entry whose keys other
# than :surface and :only are all nil/false (so a bearer-only rule is not one).
module Lakeraven
  module EHR
    class DisclosureProbeUngatedController < ApplicationController; end
    class DisclosureProbeOtherActionController < ApplicationController
      disclosure_surface :fhir_api, only: :index
    end
    class DisclosureProbeGatedController < ApplicationController
      disclosure_surface :fhir_api
    end
    class DisclosureProbeRaisingController < ActionController::API
      include DisclosureSurfaceGate
      disclosure_surface :fhir_api, if: :boom
      def show = head(:no_content)
      def boom = raise("boom")
    end
  end
end

class FhirApiDisclosureSurfaceTest < ActionDispatch::IntegrationTest
  include SmartAuthTestHelper

  EHR = Lakeraven::EHR
  Surfaces = EHR::DisclosureSurfaces
  ABSENT = Object.new.freeze
  BASE = "/lakeraven-ehr"
  NS = "lakeraven/ehr/"
  OTHER_SURFACES = %w[exports export_files ccda_imports transitions_of_care].freeze
  EXPECTED = (
    %w[patients practitioners allergy_intolerances conditions medication_requests observations encounters
       locations service_requests immunizations procedures audit_events value_sets]
      .flat_map { |c| [ "#{c}#index", "#{c}#show" ] } +
    %w[organizations#show coverage_eligibility_requests#create measures#index measures#import
       measure_reports#index value_sets#expand]
  ).freeze
  CLOSED_CONFIGS = [ [ "absent", ABSENT ], [ "bulk_export and ccda only", %i[bulk_export ccda] ] ].freeze
  BROWSER_ROUTES = [
    [ "charts#show",             :get,  "#{BASE}/patients/1" ],
    [ "screenings#index",        :get,  "#{BASE}/patients/1/screenings" ],
    [ "patient_contexts#create", :post, "#{BASE}/patients/1/context" ]
  ].freeze
  HOST_ROUTES = [ [ :get, "/Patient/1" ], [ :get, "/Observation" ], [ :post, "/Measure/$import" ] ].freeze
  # SMART App Launch is part of the fhir_api surface: it is how an app gets a patient's token.
  SMART_LAUNCH_ROUTES = (
    %w[smart/launch oauth/authorize oauth/authorize/approval oauth/authorize/patient]
      .flat_map { |path| [ [ :get, path, {} ], [ :post, path, {} ] ] } +
    [ [ :post, "oauth/token", { grant_type: "authorization_code", code: "junk" } ] ]
  ).freeze
  SMART_LAUNCH_CONTROLLERS = %w[smart_launch smart_authorizations smart_tokens].freeze
  STAYS_OPEN = [
    [ :get, "metadata", {}, [ 200 ] ], [ :get, ".well-known/smart-configuration", {}, [ 200 ] ],
    [ :get, "smart/style", {}, [ 200 ] ], [ :post, "oauth/token", { grant_type: "client_credentials" }, [ 400, 401 ] ]
  ].freeze
  BEARER_ROWS = [
    [ "Bearer abc", true ], [ "bearer abc", true ], [ "BEARER a.b-c", true ], [ nil, false ], [ "", false ],
    [ "Basic dXNlcjpwYXNz", false ], [ "Bearer", false ], [ "Bearer ", false ], [ "Token abc", false ]
  ].freeze

  setup { @saved_options = Rails.application.config.x.lakeraven_ehr }

  teardown do
    Rails.application.config.x.lakeraven_ehr = @saved_options
    EHR::ExportsController.reset_store!
    teardown_smart_auth
  end

  test "the table is every FHIR API route the engine draws, and names each expected one" do
    assert_empty EXPECTED - fhir_routes.map(&:first)
  end

  CLOSED_CONFIGS.each do |label, value|
    [ [ "no token", nil ], [ "a fully scoped token", "system/*.read system/*.write" ] ].each do |who, scopes|
      test "every FHIR route answers 404, and not from the engine, to #{who} when the config is #{label}" do
        setup_smart_auth(scopes: scopes) if scopes
        configure(value)
        open = fhir_routes.filter_map do |name, verb, path|
          send(verb, path, headers: @headers || {})
          "#{name} #{response.status}" unless response.status == 404 && host_answered?
        end
        assert_empty open
      end
    end

    test "FHIR routes are not recognised when the config is #{label}" do
      configure(value)
      assert_raises(ActionController::RoutingError) { EHR::Engine.routes.recognize_path("/Patient/1") }
      assert_raises(ActionController::RoutingError) { EHR::Engine.routes.recognize_path("/Measure/$import", method: :post) }
    end

    BROWSER_ROUTES.each do |name, verb, path|
      test "#{name} refuses a bearer request with a bare 404 when the config is #{label}" do
        configure(value)
        send(verb, path, headers: { "Authorization" => "bEARER not-a-real-token" })
        assert_closed
      end
    end
  end

  test "with fhir_api opened every FHIR route is recognised and answers 401 without a token" do
    configure(%i[fhir_api])
    assert_equal "show", EHR::Engine.routes.recognize_path("/Patient/1")[:action]
    wrong = fhir_routes.filter_map do |name, verb, path|
      send(verb, path)
      "#{name} #{response.status}" unless response.status == 401
    end
    assert_empty wrong
  end

  # The controller's own gate: a host route that bypasses the engine's constraint.
  test "a host route drawn straight at a FHIR controller is refused with a bare 404 while closed" do
    setup_smart_auth(scopes: "system/*.read system/*.write")
    with_routing do |set|
      set.draw do
        get "Patient/:dfn", to: "lakeraven/ehr/patients#show"
        get "Observation", to: "lakeraven/ehr/observations#index"
        post "Measure/$import", to: "lakeraven/ehr/measures#import"
      end
      rows = CLOSED_CONFIGS.flat_map { |_, value| [ [ value, {}, 404 ], [ value, @headers, 404 ] ] } + [ [ %i[fhir_api], {}, 401 ] ]
      wrong = rows.product(HOST_ROUTES).filter_map do |(value, headers, status), (verb, path)|
        configure(value)
        send(verb, path, headers: headers)
        next if response.status == status && (status == 401 || response.body.empty?)
        "#{verb} #{path} #{value.equal?(ABSENT) ? :absent : value.inspect} token=#{headers.any?} -> #{response.status}"
      end
      assert_empty wrong
    end
  end

  test "RouteConstraint matches only while its surface is open and refuses an unknown name" do
    constraint = Surfaces::RouteConstraint.new(:fhir_api)
    request = ActionDispatch::Request.new({})
    [ [ ABSENT, false ], [ %i[bulk_export ccda], false ], [ %i[fhir_api], true ] ].each do |value, expected|
      configure(value)
      assert_equal expected, constraint.matches?(request), value.inspect
    end
    assert_raises(ArgumentError) { Surfaces::RouteConstraint.new(:nope) }
  end

  test "each FHIR resource controller declares fhir_api itself for every action routed to it" do
    undeclared = fhir_routes.map(&:first).reject do |name|
      controller, action = name.split("#")
      unconditional_rules("#{NS}#{controller}_controller".camelize.constantize, action)
        .any? { |rule| rule[:surface] == :fhir_api }
    end
    assert_empty undeclared
  end

  test "bearer_authorization? is true only for a Bearer header carrying a token" do
    BEARER_ROWS.each do |header, expected|
      request = ActionDispatch::Request.new(header.nil? ? {} : { "HTTP_AUTHORIZATION" => header })
      assert_equal expected, EHR::SmartAuthentication.bearer_authorization?(request), header.inspect
    end
  end

  test "the gate leaves a browser request without a bearer header to the chart's own sign-in" do
    configure(ABSENT)
    [ {}, { "Authorization" => "Basic dXNlcjpwYXNz" } ].each do |headers|
      get "#{BASE}/patients/1", headers: headers
      assert_not_equal 404, response.status, headers.inspect
    end
    post "#{BASE}/login", params: { username: "testprovider", password: "test123" }
    get "#{BASE}/patients/1"
    assert_not_equal 404, response.status
  end

  test "discovery, the launch style and the backend services token stay open with every surface closed" do
    configure(ABSENT)
    STAYS_OPEN.each do |verb, path, params, statuses|
      send(verb, "#{BASE}/#{path}", params: params)
      assert_includes statuses, response.status, path
    end
  end

  [ *CLOSED_CONFIGS.map { |label, value| [ label, value, true ] }, [ "fhir_api", %i[fhir_api], false ] ].each do |label, value, closed|
    test "the SMART launch flow #{closed ? 'answers 404' : 'is served'} when the config is #{label}" do
      configure(value)
      wrong = SMART_LAUNCH_ROUTES.filter_map do |verb, path, params|
        send(verb, "#{BASE}/#{path}", params: params)
        "#{verb} #{path} #{response.status}" unless closed ? response.status == 404 && host_answered? : response.status != 404
      end
      assert_empty wrong
    end
  end

  test "each SMART launch controller declares fhir_api itself for every action routed to it" do
    routed = EHR::Engine.routes.routes.map { |route| route.defaults.values_at(:controller, :action) }
      .select { |controller, _| SMART_LAUNCH_CONTROLLERS.include?(controller.to_s.delete_prefix(NS)) }.uniq
    assert_equal SMART_LAUNCH_CONTROLLERS, routed.map { |controller, _| controller.delete_prefix(NS) }.uniq.sort_by { |c| SMART_LAUNCH_CONTROLLERS.index(c) }
    undeclared = routed.reject do |controller, action|
      klass = "#{controller}_controller".camelize.constantize
      klass.respond_to?(:disclosure_surface_rules) && unconditional_rules(klass, action).any? { |rule| rule[:surface] == :fhir_api }
    end
    assert_empty undeclared.map { |pair| pair.join("#") }
  end

  test "a rule whose predicate raises fails closed, and serves once the surface is open" do
    with_routing do |set|
      set.draw { get "Probe", to: "#{NS}disclosure_probe_raising#show" }
      [ [ ABSENT, 404 ], [ %i[bulk_export ccda], 404 ], [ %i[fhir_api], 204 ] ].each do |value, status|
        configure(value)
        get "/Probe"
        assert_equal [ status, "" ], [ response.status, response.body ], value.inspect
      end
    end
  end

  test "a bearer client on exports is bulk_export, not fhir_api" do
    setup_smart_auth(scopes: "system/*.read system/*.write")
    [ [ %i[bulk_export], 202 ], [ %i[fhir_api], 404 ] ].each do |value, status|
      configure(value)
      post "#{BASE}/exports", params: { export_type: "patient", patient_dfn: "1" }, headers: @headers
      assert_equal status, response.status, value.inspect
    end
  end

  test "the engine has no ungated FHIR API route outside the documented allowlist" do
    assert_empty Surfaces.ungated_routes(EHR::Engine.routes)
    allow = Surfaces::UNGOVERNED_API_ROUTES
    assert_predicate allow, :frozen?
    assert allow.all? { |route, reason| route.include?("#") && reason.is_a?(String) && reason.present? }
    assert_empty allow.keys & fhir_routes.map { |name, *| "#{NS}#{name}" }
  end

  COVERAGE_ROWS = [
    [ "a controller with no disclosure_surface", "Widget/:id", "disclosure_probe_ungated#show",      true ],
    [ "a controller gating only another action", "Widget/:id", "disclosure_probe_other_action#show", true ],
    [ "an uppercase path on a non-API controller", "Gadget",   "capability_statements#show",         true ],
    [ "a $operation on a non-API controller",    "$probe",     "capability_statements#show",         true ],
    [ "an uppercase segment after a prefix",     "fhir/Patient/:id", "capability_statements#show",   true ],
    [ "an uppercase segment after an optional scope", "(:tenant)/Observation", "capability_statements#show", true ],
    [ "a $operation after a lowercase segment",  "widgets/$probe", "capability_statements#show",     true ],
    [ "lowercase segments and params only",      "widgets/:id/parts", "capability_statements#show",  false ],
    [ "a controller declaring fhir_api",         "Widget/:id", "disclosure_probe_gated#show",        false ],
    [ "a lowercase path on a non-API controller", "widgets",   "capability_statements#show",         false ]
  ].freeze

  COVERAGE_ROWS.each do |label, path, target, reported|
    test "the coverage check #{reported ? 'reports' : 'passes'} #{label}" do
      set = ActionDispatch::Routing::RouteSet.new
      set.draw { get path, to: "#{NS}#{target}" }
      assert_equal (reported ? [ "#{NS}#{target}" ] : []), Surfaces.ungated_routes(set, allow: [])
      assert_empty Surfaces.ungated_routes(set, allow: [ "#{NS}#{target}" ])
    end
  end

  private

  # [ "controller#action", verb, path ] for every engine route to a bearer-only
  # API controller that is not another surface's, path params filled with "1".
  def fhir_routes
    EHR::Engine.routes.routes.filter_map do |route|
      controller = route.defaults[:controller].to_s.delete_prefix(NS)
      klass = "#{route.defaults[:controller]}_controller".camelize.safe_constantize
      next unless klass && klass < EHR::ApplicationController && OTHER_SURFACES.exclude?(controller)

      [ "#{controller}##{route.defaults[:action]}", route.verb.downcase.to_sym,
        BASE + route.format(route.required_parts.index_with { "1" }) ]
    end
  end

  def unconditional_rules(klass, action)
    klass.disclosure_surface_rules.select do |rule|
      (rule[:only].nil? || rule[:only].include?(action)) && rule.except(:surface, :only).values.none?
    end
  end

  def configure(value)
    options = ActiveSupport::OrderedOptions.new
    options[:open_disclosure_surfaces] = value unless value.equal?(ABSENT)
    Rails.application.config.x.lakeraven_ehr = options
  end

  # A 404 the host's router gave (its own page), not an answer from the engine.
  def host_answered?
    response.media_type != "application/fhir+json" && !response.body.match?(/resourceType|OperationOutcome/)
  end

  def assert_closed
    assert_response :not_found
    assert_empty response.body
  end
end
