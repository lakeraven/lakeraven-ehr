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
class DisclosureSurfacesRouteCoverageTest < ActionDispatch::IntegrationTest
  include SmartAuthTestHelper

  MOUNT = "/lakeraven-ehr"
  # Synthetic BASELINE_MOCK_SEEDS patient (test/test_helper.rb): "Anderson,Alice".
  PATIENT_NAME_PARTS = %w[Anderson Alice].freeze

  # The FHIR resource controllers in the fhir_api block of config/routes.rb.
  # Every action routed at one of these is governed.
  FHIR_API_CONTROLLERS = %w[
    patients practitioners allergy_intolerances conditions medication_requests
    observations encounters organizations locations service_requests
    immunizations procedures coverage_eligibility_requests measure_reports
    audit_events value_sets
  ].map { |name| "lakeraven/ehr/#{name}" }.freeze

  # The bulk_export and ccda surfaces: every action of each controller.
  EXPORT_AND_CCDA_CONTROLLERS = %w[exports export_files transitions_of_care]
    .map { |name| "lakeraven/ehr/#{name}" }.freeze

  GOVERNED_CONTROLLERS = (FHIR_API_CONTROLLERS + EXPORT_AND_CCDA_CONTROLLERS).freeze

  # Governed by action, not by controller: Measure/$import on the same
  # controller is ingest and stays routed (see ALLOWLIST).
  GOVERNED_ROUTE_KEYS = %w[lakeraven/ehr/measures#index].freeze

  # Routes the switch deliberately leaves open. Each entry renders NO record
  # content; the justification is beside it.
  ALLOWLIST = %w[
    lakeraven/ehr/capability_statements#show
    lakeraven/ehr/smart_configuration#show
    lakeraven/ehr/smart_tokens#create
    lakeraven/ehr/backend_services#token
    lakeraven/ehr/ccda_imports#create
    lakeraven/ehr/measures#import
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
  # ccda_imports#create         — INBOUND C-CDA for reconciliation: ingest, not
  #                               egress. Answers an OperationOutcome whose
  #                               diagnostics is a fixed sentence; the request
  #                               body is the only record content involved and
  #                               it came from the caller.
  # measures#import             — Measure/$import: creates a Measure definition
  #                               (a quality-measure spec, not patient data)
  #                               and answers an OperationOutcome naming the
  #                               measure id. No record content.
  #
  # Audit of the remaining ungoverned engine routes (ActionController::API,
  # not the FHIR base, so the completeness guard does not reach them):
  #   smart_styles#show — SMART styling JSON (colours), no record content.
  # Every other engine controller is WebController or ActionController::Base
  # (browser session surfaces, the chart and demo visits) and is path 1, not
  # paths 2–4; the HTML chart's own bearer refusal is spec'd in
  # test/integration/disclosure_surfaces_test.rb (gap A).

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
    GOVERNED_CONTROLLERS.include?(route.defaults[:controller]) || GOVERNED_ROUTE_KEYS.include?(route_key(route))
  end

  def api_base_controller?(route)
    klass = "#{route.defaults[:controller]}_controller".camelize.safe_constantize
    klass.is_a?(Class) && klass <= Lakeraven::EHR::ApplicationController
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
    refute_includes keys, "lakeraven/ehr/measures#import", "Measure/$import is ingest and is not governed"
    # 36 today: 31 in the fhir_api block, exports 3 + export_files 1, transitions_of_care 1.
    # A route leaving the governed set is a change a reviewer should see.
    assert_operator keys.length, :>=, 36,
      "expected the fhir_api block, exports and C-CDA to enumerate to at least 36 routes (got #{keys.length})"
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
end
