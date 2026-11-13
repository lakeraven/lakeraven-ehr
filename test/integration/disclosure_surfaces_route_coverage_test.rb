# frozen_string_literal: true

require "test_helper"

# Every governed engine route is closed by the disclosure-surface switch, not
# just the handful the behavioural spec names (#522 amendment 1, gap D).
#
# Two guards, read against Lakeraven::EHR::Engine.routes.routes:
#
#   1. Every route whose controller is one of the FHIR resource controllers
#      in the fhir_api block of config/routes.rb, or the exports, export_files
#      or transitions_of_care controllers, answers 404 with no broker call and
#      no clinical content when everything is closed — a valid all-scopes
#      token, the route's own verb, synthetic segment values.
#   2. Completeness: every engine route whose controller class descends from
#      Lakeraven::EHR::ApplicationController (the FHIR API base) is either in
#      that governed set or in the explicit allowlist below. A new API
#      controller cannot be routed ungoverned without a reviewer naming it.
#
# Amendment 2 (gaps E and G) adds:
#
#   3. The header-token sweep (gap E): every engine route whose controller
#      class includes Lakeraven::EHR::SmartAuthentication — computed from the
#      class, directly or through BrowserSmartAuthentication, never from a
#      hand list — answers 404 with no broker call to a valid all-scopes
#      Bearer with no session while everything is closed. Positively, for
#      screenings#show and patient_contexts#create, the same request with
#      fhir_api OPEN is not 404, so the 404 is the switch's.
#   4. The controllers' own rules (gap G): "governed" above is this file's
#      list, so deleting `disclosure_surface :fhir_api` from a controller kept
#      the suite green (the engine routes still 404 through the routing
#      constraint). Every governed route's controller class must itself
#      declare a disclosure_surface rule naming the expected surface that
#      governs that action (`only:` respected). Measure/$import and
#      ccda_imports#create are FHIR API calls on the FHIR base, bearer-only,
#      so they are fhir_api too, unconditionally: inbound C-CDA ingest drops
#      Part 2 security labels today (Half 2 of #522) and must not run while
#      the API is closed. The completeness guard also widens past the FHIR base:
#      every routed engine controller that is an ActionController::API, or
#      that includes SmartAuthentication, is governed or allowlisted with a
#      justification.
class DisclosureSurfacesRouteCoverageTest < ActionDispatch::IntegrationTest
  include SmartAuthTestHelper

  MOUNT = "/lakeraven-ehr"
  # Synthetic BASELINE_MOCK_SEEDS patient (test/test_helper.rb): "Anderson,Alice".
  PATIENT_NAME_PARTS = %w[Anderson Alice].freeze

  # The FHIR API controllers: the resource controllers in the fhir_api block
  # of config/routes.rb, plus the two FHIR operations routed outside it on
  # the same base — Measure (index and $import) and the inbound C-CDA import.
  # Every action routed at one of these is governed by fhir_api.
  FHIR_API_CONTROLLERS = %w[
    patients practitioners allergy_intolerances conditions medication_requests
    observations encounters organizations locations service_requests
    immunizations procedures coverage_eligibility_requests measures measure_reports
    audit_events value_sets ccda_imports
  ].map { |name| "lakeraven/ehr/#{name}" }.freeze

  # The bulk_export and ccda surfaces: every action of each controller.
  EXPORT_AND_CCDA_CONTROLLERS = %w[exports export_files transitions_of_care]
    .map { |name| "lakeraven/ehr/#{name}" }.freeze

  GOVERNED_CONTROLLERS = (FHIR_API_CONTROLLERS + EXPORT_AND_CCDA_CONTROLLERS).freeze

  # The surface each governed controller must declare for itself (gap G),
  # for every one of its routed actions — Measure's index AND $import.
  EXPECTED_SURFACES = FHIR_API_CONTROLLERS.index_with { :fhir_api }.merge(
    "lakeraven/ehr/exports" => :bulk_export,
    "lakeraven/ehr/export_files" => :bulk_export,
    "lakeraven/ehr/transitions_of_care" => :ccda
  ).freeze

  # Routes the switch deliberately leaves ungoverned by a disclosure_surface
  # rule. Each entry either renders NO record content or is a browser (path
  # 1) surface whose header-token refusal is spec'd separately (gap E); the
  # justification is beside it.
  ALLOWLIST = %w[
    lakeraven/ehr/capability_statements#show
    lakeraven/ehr/smart_configuration#show
    lakeraven/ehr/smart_styles#show
    lakeraven/ehr/smart_tokens#create
    lakeraven/ehr/backend_services#token
    lakeraven/ehr/charts#show
    lakeraven/ehr/screenings#index
    lakeraven/ehr/screenings#new
    lakeraven/ehr/screenings#create
    lakeraven/ehr/screenings#show
    lakeraven/ehr/patient_contexts#create
    lakeraven/ehr/allergies#new
    lakeraven/ehr/allergies#create
    lakeraven/ehr/allergies#no_known_allergies
    lakeraven/ehr/consents#index
    lakeraven/ehr/consents#new
    lakeraven/ehr/consents#handover
    lakeraven/ehr/consents#revocation
    lakeraven/ehr/consent_kiosk#show
    lakeraven/ehr/consent_kiosk#create
    lakeraven/ehr/consent_kiosk#unlock
  ].freeze
  # capability_statements#show  — /metadata, the server's CapabilityStatement:
  #                               static server description, no patient data.
  #                               (ActionController::API, not the FHIR base;
  #                               listed because the brief names it.)
  # smart_configuration#show    — SMART discovery document: endpoint URLs only.
  #                               (ActionController::API; listed as above.)
  # smart_tokens#create         — OAuth token endpoint, authorization-code
  #                               grant: issues a credential, reads no record.
  #                               (ActionController::API; listed as above.)
  # backend_services#token      — OAuth token endpoint, client_credentials
  #                               grant: same. (ActionController::API.)
  # smart_styles#show           — SMART styling JSON (colours), no record
  #                               content. (ActionController::API; reached by
  #                               the widened completeness guard.)
  # charts#show                 — the HTML chart, path 1 for a browser session.
  #                               Its rule is CONDITIONAL (`if:
  #                               :fhir_api_request?`), so it is not in the
  #                               unconditional governed set; the FHIR
  #                               representations and the header-token read
  #                               are spec'd in disclosure_surfaces_test.rb
  #                               (gaps A, B, F) and in the sweep below.
  # screenings#*, patient_contexts#create, allergies#*, consents#*,
  # consent_kiosk#*             — browser (path 1) surfaces on WebController
  #                               that authenticate through
  #                               BrowserSmartAuthentication. A browser
  #                               session reads them with no Authorization
  #                               header while everything is closed; a
  #                               header Bearer is refused by the gap E rule,
  #                               spec'd in the sweep below and in
  #                               disclosure_surfaces_test.rb.
  #
  # Every other engine controller is WebController or ActionController::Base
  # without SmartAuthentication (sign-on, dashboards, registration, scheduling,
  # demo visits) and is path 1, not paths 2–4.

  setup do
    @config = Rails.application.config.x.lakeraven_ehr
    @had_key = @config.key?(:open_disclosure_surfaces)
    @original_surfaces = @config.open_disclosure_surfaces
    setup_smart_auth(scopes: "system/*.read system/*.write")
    Lakeraven::EHR::ExportsController.reset_store!
  end

  teardown do
    if @had_key
      @config.open_disclosure_surfaces = @original_surfaces
    else
      @config.delete(:open_disclosure_surfaces)
    end
    teardown_smart_auth
    Lakeraven::EHR::ExportsController.reset_store!
  end

  # -- Route enumeration --------------------------------------------------------

  Probe = Struct.new(:key, :verb, :path, keyword_init: true) do
    def label = "#{verb.upcase} #{path} (#{key})"
  end

  def engine_routes
    Lakeraven::EHR::Engine.routes.routes.select do |route|
      route.defaults[:controller].present? && route.defaults[:action].present?
    end
  end

  def route_key(route)
    "#{route.defaults[:controller]}##{route.defaults[:action]}"
  end

  def governed?(route)
    GOVERNED_CONTROLLERS.include?(route.defaults[:controller])
  end

  def controller_class(route)
    klass = "#{route.defaults[:controller]}_controller".camelize.safe_constantize
    klass.is_a?(Class) ? klass : nil
  end

  def api_base_controller?(route)
    klass = controller_class(route)
    klass && klass <= Lakeraven::EHR::ApplicationController
  end

  # Can this route's controller authenticate a header bearer token? Read from
  # the class — SmartAuthentication included directly (the FHIR base, the
  # chart) or through BrowserSmartAuthentication (the browser surfaces).
  def header_token_controller?(route)
    klass = controller_class(route)
    klass && klass.include?(Lakeraven::EHR::SmartAuthentication)
  end

  # Widened completeness (gap G): an API controller, or any controller that
  # can authenticate a header token.
  def api_or_header_token_controller?(route)
    klass = controller_class(route)
    klass && (klass <= ActionController::API || klass.include?(Lakeraven::EHR::SmartAuthentication))
  end

  def header_token_probes
    engine_routes.select { |route| header_token_controller?(route) }.map { |route| probe_for(route) }
  end

  # The controller's own disclosure_surface declarations that govern the
  # action — `only:` respected. A controller without the gate has none.
  def rules_governing(klass, action)
    return [] unless klass.respond_to?(:disclosure_surface_rules)

    klass.disclosure_surface_rules.select { |rule| rule.actions.nil? || rule.actions.include?(action.to_s) }
  end

  # The route's path with every dynamic segment replaced by a synthetic
  # value and the optional format dropped, under the engine mount. Literal
  # segments such as "$expand" are kept as written.
  def probe_for(route)
    verb = route.verb.to_s.delete_prefix("^").delete_suffix("$").downcase
    verb = "get" if verb.blank?
    path = route.path.spec.to_s.gsub("(.:format)", "").gsub(/:\w+/, "1")
    Probe.new(key: route_key(route), verb: verb, path: "#{MOUNT}#{path}")
  end

  def governed_probes
    engine_routes.select { |route| governed?(route) }.map { |route| probe_for(route) }
  end

  def issue(probe)
    public_send(probe.verb, probe.path, headers: @headers)
  end

  # -- Closed-surface assertions, collected so one run names every offender --

  def closed_surface_failures(probe)
    failures = []
    failures << "expected 404, got #{response.status}" unless response.status == 404
    body = response.body
    PATIENT_NAME_PARTS.each do |part|
      failures << "body carries the patient's name (#{part})" if body.include?(part)
    end
    failures << "body carries a Patient resource" if body.match?(/"resourceType"\s*:\s*"Patient"/)
    failures << "body carries a Bundle" if body.match?(/"resourceType"\s*:\s*"Bundle"/)
    failures << "body carries a C-CDA" if body.include?("ClinicalDocument")
    failures << "body is an OperationOutcome (the surface answered)" if body.match?(/"resourceType"\s*:\s*"OperationOutcome"/)
    failures.map { |failure| "#{probe.label}: #{failure}" }
  end

  # ============================================================================

  test "the governed set covers every FHIR resource, export and C-CDA controller that is routed" do
    routed = engine_routes.map { |route| route.defaults[:controller] }.uniq
    missing = GOVERNED_CONTROLLERS.reject { |controller| routed.include?(controller) }
    assert_empty missing, "governed controllers with no engine route (stale list?): #{missing.inspect}"

    keys = governed_probes.map(&:key)
    assert_includes keys, "lakeraven/ehr/measures#index"
    assert_includes keys, "lakeraven/ehr/value_sets#expand", "ValueSet/$expand must be in the governed set"
    assert_includes keys, "lakeraven/ehr/export_files#show"
    # FHIR API calls routed outside the fhir_api block, on the FHIR base:
    # governed by fhir_api all the same (amendment 2, lead decision).
    assert_includes keys, "lakeraven/ehr/measures#import", "Measure/$import is a FHIR API call and is governed by fhir_api"
    assert_includes keys, "lakeraven/ehr/ccda_imports#create", "the inbound C-CDA import is a FHIR API call and is governed by fhir_api"
    # 38 today: 31 in the fhir_api block, Measure/$import 1, ccda_imports 1,
    # exports 3 + export_files 1, transitions_of_care 1.
    # A route leaving the governed set is a change a reviewer should see.
    assert_operator keys.length, :>=, 38,
      "expected the fhir_api block, the two FHIR operations, exports and C-CDA to enumerate to at least 38 routes (got #{keys.length})"
  end

  test "everything closed: every governed engine route is 404 with no broker call and no clinical content" do
    @config.open_disclosure_surfaces = nil
    probes = governed_probes
    refute_empty probes

    failures = []
    probes.each do |probe|
      before = RpmsRpc.client.received_calls.length
      issue(probe)
      failures.concat(closed_surface_failures(probe))
      calls = RpmsRpc.client.received_calls.length - before
      failures << "#{probe.label}: #{calls} broker call(s) made" unless calls.zero?
    end

    assert_empty failures, "closed surfaces that still answered:\n  " + failures.join("\n  ")
  end

  # Closed before authentication: the same enumeration with no token at all
  # must get the same 404s, never a 401 that confirms the route exists.
  test "everything closed: every governed engine route is 404, not 401, with no token" do
    @config.open_disclosure_surfaces = nil
    @headers = {}

    failures = []
    governed_probes.each do |probe|
      issue(probe)
      failures << "#{probe.label}: expected 404 with no token, got #{response.status}" unless response.status == 404
    end

    assert_empty failures, failures.join("\n  ")
  end

  test "completeness: every engine route on the FHIR API base is governed or explicitly allowlisted" do
    ungoverned = engine_routes.select { |route| api_base_controller?(route) }
                              .reject { |route| governed?(route) || ALLOWLIST.include?(route_key(route)) }
                              .map { |route| probe_for(route).label }
                              .uniq

    assert_empty ungoverned,
      "engine routes on Lakeraven::EHR::ApplicationController that no disclosure surface governs " \
      "and the allowlist does not name (justify each in ALLOWLIST, or govern it):\n  " + ungoverned.join("\n  ")
  end

  # The allowlist is a reviewed exception list, so it must not drift: an
  # entry that is governed, or no longer routed, is a stale justification.
  test "completeness: the allowlist names only routed, ungoverned actions" do
    keys = engine_routes.map { |route| route_key(route) }.uniq
    stale = ALLOWLIST.reject { |key| keys.include?(key) }
    assert_empty stale, "allowlisted actions with no engine route: #{stale.inspect}"

    governed_keys = engine_routes.select { |route| governed?(route) }.map { |route| route_key(route) }
    doubled = ALLOWLIST & governed_keys
    assert_empty doubled, "allowlisted actions that are also governed: #{doubled.inspect}"
  end

  # ============================================================================
  # Gap E: the header-token sweep
  # ============================================================================

  # The sweep is computed from the classes. Pin that it reaches what it must
  # — every browser surface that authenticates a header, the chart and the
  # FHIR base — and nothing that cannot authenticate one.
  test "the header-token sweep enumerates every engine route whose controller includes SmartAuthentication" do
    keys = header_token_probes.map(&:key)

    %w[
      charts#show patients#show patients#index
      screenings#index screenings#show screenings#new screenings#create
      patient_contexts#create
      allergies#new allergies#create allergies#no_known_allergies
      consents#index consents#new consents#handover consents#revocation
      consent_kiosk#show consent_kiosk#create consent_kiosk#unlock
    ].each do |key|
      assert_includes keys, "lakeraven/ehr/#{key}", "#{key} authenticates a header token and must be swept"
    end

    # No SmartAuthentication: the sign-on page, the OAuth endpoints and the
    # discovery documents cannot authenticate a header token.
    %w[sessions#new sessions#create smart_tokens#create backend_services#token
       capability_statements#show smart_configuration#show smart_styles#show].each do |key|
      refute_includes keys, "lakeraven/ehr/#{key}", "#{key} cannot authenticate a header token and must not be swept"
    end

    # Every governed route is a header-token route: the FHIR base includes
    # SmartAuthentication. The sweep is a superset of the governed set.
    assert_empty governed_probes.map(&:key) - keys
  end

  # While everything is closed, a valid all-scopes Bearer with NO session is
  # refused by every one of those routes: 404, no broker call, no clinical
  # content. The route's own verb and synthetic segments. Routes that would
  # 404 for another reason (an id that does not exist) still satisfy the
  # assertion; the positive test below proves the refusal is the switch's.
  # The cookie jar is reset before every probe, so no request rides a cookie
  # an earlier one set — this client has never signed in through a browser.
  test "everything closed: every engine route that authenticates a header token is 404 to a Bearer with no session, with no broker call" do
    @config.open_disclosure_surfaces = nil
    probes = header_token_probes
    refute_empty probes

    failures = []
    probes.each do |probe|
      reset!
      before = RpmsRpc.client.received_calls.length
      issue(probe)
      failures.concat(closed_surface_failures(probe))
      failures << "#{probe.label}: body carries a screening" if response.body.include?("PHQ-9")
      failures << "#{probe.label}: body carries a form (the surface rendered)" if response.body.include?("<form")
      calls = RpmsRpc.client.received_calls.length - before
      failures << "#{probe.label}: #{calls} broker call(s) made" unless calls.zero?
    end

    assert_empty failures, "header-token surfaces that still answered a Bearer while everything was closed:\n  " + failures.join("\n  ")
  end

  # The same Bearer request, the same synthetic segments, with fhir_api OPEN:
  # not 404. Whatever these surfaces answer a system token (403 for a record
  # no context was opened on, 302 for a context opened) is their own specs'
  # business; what this pins is that the closed-state 404 came from the
  # switch, not from the synthetic id or from some other refusal.
  test "fhir_api open: a Bearer with no session is not 404 at screenings#show and patient_contexts#create" do
    @config.open_disclosure_surfaces = [ :fhir_api ]
    probes = header_token_probes.index_by(&:key)

    %w[lakeraven/ehr/screenings#show lakeraven/ehr/patient_contexts#create].each do |key|
      probe = probes.fetch(key) { flunk "#{key} is not in the header-token sweep" }
      reset!
      issue(probe)
      refute_equal 404, response.status,
        "#{probe.label}: with fhir_api open the same Bearer request must not be 404 (the closed 404 must be the switch's)"
    end
  end

  # ============================================================================
  # Gap G: the controllers' own rules
  # ============================================================================

  # "Governed" is decided above from this file's list; the controller has to
  # agree. Every governed route's controller class declares a
  # disclosure_surface rule naming the expected surface, unconditional, that
  # governs that action. Deleting `disclosure_surface :fhir_api` from
  # observations_controller.rb must fail here, whatever the routing
  # constraint still does.
  test "every governed engine route's controller declares an unconditional disclosure_surface rule for the expected surface that governs the action" do
    failures = []

    engine_routes.select { |route| governed?(route) }.each do |route|
      label = probe_for(route).label
      klass = controller_class(route)
      action = route.defaults[:action].to_s
      expected = EXPECTED_SURFACES.fetch(route.defaults[:controller]) { flunk "#{label}: no expected surface (extend EXPECTED_SURFACES)" }

      unless klass.respond_to?(:disclosure_surface_rules)
        failures << "#{label}: #{klass} has no disclosure_surface_rules (DisclosureSurfaceGate not included)"
        next
      end

      governing = rules_governing(klass, action)
      if governing.empty?
        failures << "#{label}: no disclosure_surface rule governs #{action} (rules: #{klass.disclosure_surface_rules.map(&:surface).inspect})"
        next
      end

      matching = governing.select { |rule| rule.surface.to_sym == expected }
      if matching.empty?
        failures << "#{label}: rules governing #{action} name #{governing.map(&:surface).inspect}, expected #{expected.inspect}"
      elsif matching.none? { |rule| rule.condition.nil? }
        failures << "#{label}: the #{expected} rule governing #{action} is conditional (#{matching.map(&:condition).inspect}); a governed action must be refused unconditionally"
      end
    end

    assert_empty failures, "governed routes whose controller does not declare the rule:\n  " + failures.join("\n  ")
  end

  # Measure/$import and the inbound C-CDA import are FHIR API calls on the
  # FHIR base, bearer-only, so fhir_api governs them unconditionally, like
  # every other action on the base. Fail closed: inbound C-CDA ingest drops
  # Part 2 security labels today (Half 2 of #522) and must not run while the
  # API is closed. Today measures declares `only: :index` and ccda_imports
  # declares nothing.
  test "measures and ccda_imports: an unconditional fhir_api rule governs index, import and create" do
    {
      Lakeraven::EHR::MeasuresController => %w[index import],
      Lakeraven::EHR::CcdaImportsController => %w[create]
    }.each do |klass, actions|
      assert klass.respond_to?(:disclosure_surface_rules), "#{klass} must include DisclosureSurfaceGate"
      actions.each do |action|
        rules = rules_governing(klass, action)
        assert rules.any? { |rule| rule.surface.to_sym == :fhir_api && rule.condition.nil? },
          "#{klass}##{action} must be governed by an unconditional fhir_api rule (rules: #{klass.disclosure_surface_rules.inspect})"
      end
    end
  end

  # Widened completeness: an ActionController::API controller OR one that
  # authenticates a header token, routed by the engine, is governed or
  # allowlisted with a justification. The FHIR-base guard above is a subset
  # of this one and stays, so a reviewer sees which guard moved.
  test "completeness: every engine route on an API controller or a header-token controller is governed or explicitly allowlisted" do
    ungoverned = engine_routes.select { |route| api_or_header_token_controller?(route) }
                              .reject { |route| governed?(route) || ALLOWLIST.include?(route_key(route)) }
                              .map { |route| "#{probe_for(route).label} [#{controller_class(route)}]" }
                              .uniq

    assert_empty ungoverned,
      "engine routes on an ActionController::API or SmartAuthentication controller that no disclosure surface governs " \
      "and the allowlist does not name (justify each in ALLOWLIST, or govern it):\n  " + ungoverned.join("\n  ")
  end

  # The widened guard must actually reach past the FHIR base, or it is the
  # old guard under a new name.
  test "completeness: the widened guard reaches the API controllers off the FHIR base and the browser header-token surfaces" do
    reached = engine_routes.select { |route| api_or_header_token_controller?(route) }.map { |route| route_key(route) }.uniq

    assert_includes reached, "lakeraven/ehr/smart_styles#show", "an ActionController::API off the FHIR base"
    assert_includes reached, "lakeraven/ehr/smart_tokens#create", "an ActionController::API off the FHIR base"
    assert_includes reached, "lakeraven/ehr/charts#show", "SmartAuthentication included directly"
    assert_includes reached, "lakeraven/ehr/screenings#show", "SmartAuthentication via BrowserSmartAuthentication"
    assert_includes reached, "lakeraven/ehr/consent_kiosk#show", "SmartAuthentication via BrowserSmartAuthentication"
    refute_includes reached, "lakeraven/ehr/sessions#new", "a WebController without SmartAuthentication is path 1 and is not reached"
    refute_includes reached, "lakeraven/ehr/dashboards#show", "a WebController without SmartAuthentication is path 1 and is not reached"
  end
end
