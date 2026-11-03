# frozen_string_literal: true

require "test_helper"

# FHIR search paging (#648): _count (default 20, at most 100) and _offset on
# every search, Bundle.link self / next / previous, and total counting the
# whole match set.
class FhirSearchPagingTest < ActionDispatch::IntegrationTest
  include SmartAuthTestHelper

  setup do
    setup_smart_auth
  end

  teardown do
    teardown_smart_auth
  end

  # -- Pages -------------------------------------------------------------------

  test "a page holds _count matches while total counts all of them" do
    get "/lakeraven-ehr/Patient", params: { _count: "2" }, headers: @headers

    assert_response :ok
    assert_equal 3, bundle["total"]
    assert_equal 2, bundle["entry"].length
  end

  # Practitioner renders through render_bundle, the path most searches share;
  # Patient builds its own page.
  test "a shared-path search counts the whole match set too" do
    get "/lakeraven-ehr/Practitioner", params: { _count: "1" }, headers: @headers

    assert_response :ok
    assert_equal 2, bundle["total"]
    assert_equal 1, bundle["entry"].length
    assert link("next")
  end

  test "next and previous walk the pages, and the pages together are the match set once" do
    get "/lakeraven-ehr/Patient", headers: @headers
    everyone = entry_ids

    get "/lakeraven-ehr/Patient", params: { _count: "2" }, headers: @headers
    first_page = entry_ids
    refute link("previous"), "the first page has no previous page"

    follow link("next")
    second_page = entry_ids
    refute link("next"), "the last page has no next page"
    assert_equal 3, bundle["total"]

    assert_equal everyone, first_page + second_page

    follow link("previous")
    assert_equal first_page, entry_ids, "previous returns the same first page"
  end

  test "the same _offset returns the same entries every time" do
    get "/lakeraven-ehr/Patient", params: { _count: "1", _offset: "1" }, headers: @headers
    once = entry_ids
    get "/lakeraven-ehr/Patient", params: { _count: "1", _offset: "1" }, headers: @headers

    assert_equal once, entry_ids
    assert_equal 1, once.length
  end

  test "links repeat the search, with this page's _count and _offset" do
    get "/lakeraven-ehr/Patient", params: { name: "", _count: "1", _offset: "1" }, headers: @headers

    self_query = query_of(link("self"))
    assert_equal({ "name" => "", "_count" => "1", "_offset" => "1" }, self_query)
    assert_equal "2", query_of(link("next"))["_offset"]
    assert_equal "0", query_of(link("previous"))["_offset"]
    assert URI(link("self")).path.end_with?("/lakeraven-ehr/Patient"), link("self")
  end

  test "with no paging parameters the page is the default 20, and self says so" do
    25.times { |i| audit_row!(i) }

    get "/lakeraven-ehr/AuditEvent", headers: @headers

    assert_response :ok
    assert_equal 20, bundle["entry"].length
    assert_operator bundle["total"], :>=, 25
    assert_equal "20", query_of(link("self"))["_count"]
    assert_equal "0", query_of(link("self"))["_offset"]
    assert link("next")
  end

  test "_count=100 is accepted" do
    get "/lakeraven-ehr/Patient", params: { _count: "100" }, headers: @headers

    assert_response :ok
    assert_equal 3, bundle["entry"].length
  end

  test "_count=0 returns the total and no entries" do
    get "/lakeraven-ehr/Patient", params: { _count: "0" }, headers: @headers

    assert_response :ok
    assert_equal 3, bundle["total"]
    assert_empty bundle.fetch("entry", [])
    assert_equal %w[self], bundle["link"].map { |l| l["relation"] }
  end

  test "an _offset past the end is an empty page whose previous is the last full page" do
    get "/lakeraven-ehr/Patient", params: { _count: "2", _offset: "50" }, headers: @headers

    assert_response :ok
    assert_equal 3, bundle["total"]
    assert_empty bundle.fetch("entry", [])
    refute link("next")
    assert_equal "1", query_of(link("previous"))["_offset"]
  end

  # Reading AuditEvent writes an AuditEvent, so the set grows by one on every
  # request. Walking the pages must still see each row once.
  test "AuditEvent pages do not repeat a row while each read adds one" do
    5.times { |i| audit_row!(i) }

    get "/lakeraven-ehr/AuditEvent", params: { _count: "3" }, headers: @headers
    first_page = entry_ids
    follow link("next")
    second_page = entry_ids

    assert_equal 3, first_page.length
    assert_empty first_page & second_page, "a row appeared on two pages"
  end

  # -- _revinclude (#631) --------------------------------------------------------

  test "revinclude rows follow the page's patients only and are not counted" do
    %w[1 2 3].each { |dfn| provenance_for!(dfn) }
    setup_smart_auth(scopes: "system/Patient.read system/Provenance.read")

    get "/lakeraven-ehr/Patient",
      params: { _revinclude: "Provenance:target", _count: "1" }, headers: @headers

    assert_response :ok
    assert_equal 3, bundle["total"]
    matches = bundle["entry"].select { |e| e.dig("search", "mode") == "match" }
    included = bundle["entry"].select { |e| e.dig("search", "mode") == "include" }
    assert_equal 1, matches.length
    assert_equal [ "Patient/rpms-#{matches.first.dig('resource', 'id')}" ],
      included.flat_map { |e| e.dig("resource", "target").map { |t| t["reference"] } }.uniq
  end

  # -- Refusals ----------------------------------------------------------------

  {
    "_count" => [ "abc", "-1", "", "2.5", "101", "1000" ],
    "_offset" => [ "abc", "-1", "", "1e3" ]
  }.each do |name, values|
    values.each do |value|
      test "#{name}=#{value.inspect} is refused with a 400 OperationOutcome naming it" do
        get "/lakeraven-ehr/Patient", params: { name => value }, headers: @headers

        assert_response :bad_request
        assert_equal "OperationOutcome", bundle["resourceType"]
        issue = bundle["issue"].first
        assert_equal "invalid", issue["code"]
        assert_includes issue["diagnostics"], name
        assert_includes issue["diagnostics"], value.inspect
      end
    end
  end

  test "an unauthenticated search with a bad _count is a 401, not a 400" do
    get "/lakeraven-ehr/Patient", params: { _count: "abc" }

    assert_response :unauthorized
  end

  # -- Every search ------------------------------------------------------------

  # Every GET index the engine routes to a FHIR API controller. Built from the
  # router so a search added later is covered without editing this list.
  FHIR_SEARCH_PATHS = Lakeraven::EHR::Engine.routes.routes.filter_map do |route|
    next unless route.verb == "GET" && route.defaults[:action] == "index"

    controller = "Lakeraven::EHR::#{route.defaults[:controller].delete_prefix('lakeraven/ehr/').camelize}Controller"
    klass = controller.safe_constantize
    next unless klass && klass < Lakeraven::EHR::ApplicationController

    "/lakeraven-ehr#{route.path.spec.to_s.sub('(.:format)', '')}"
  end.uniq.freeze

  test "the route scan finds the FHIR searches" do
    assert_operator FHIR_SEARCH_PATHS.length, :>=, 14, FHIR_SEARCH_PATHS.inspect
    assert_includes FHIR_SEARCH_PATHS, "/lakeraven-ehr/Patient"
    assert_includes FHIR_SEARCH_PATHS, "/lakeraven-ehr/AuditEvent"
    refute FHIR_SEARCH_PATHS.any? { |p| p.include?("screenings") }, "screenings is a web page, not a FHIR search"
  end

  FHIR_SEARCH_PATHS.each do |path|
    test "#{path} pages: a Bundle with self link, and a bad _count is a 400" do
      get path, params: { patient: "1" }, headers: @headers
      assert_response :ok
      assert_equal "Bundle", bundle["resourceType"]
      assert_equal "20", query_of(link("self"))["_count"]

      get path, params: { patient: "1", _count: "abc" }, headers: @headers
      assert_response :bad_request
      assert_equal "OperationOutcome", bundle["resourceType"]
    end
  end

  # -- Declaration ---------------------------------------------------------------

  test "the declared limits are the enforced ones" do
    declared = Lakeraven::EHR::FHIR::SearchCapabilities.rest_search_params.map { |p| p[:name] }
    assert_empty %w[_count _offset] - declared

    max = Lakeraven::EHR::FHIR::SearchCapabilities::MAX_COUNT
    get "/lakeraven-ehr/Patient", params: { _count: max.to_s }, headers: @headers
    assert_response :ok
    get "/lakeraven-ehr/Patient", params: { _count: (max + 1).to_s }, headers: @headers
    assert_response :bad_request
  end

  private

  def bundle
    JSON.parse(response.body)
  end

  def entry_ids
    bundle.fetch("entry", []).map { |e| e.dig("resource", "id") }
  end

  def link(relation)
    bundle.fetch("link", []).find { |l| l["relation"] == relation }&.fetch("url")
  end

  def query_of(url)
    Rack::Utils.parse_query(URI(url).query)
  end

  def follow(url)
    uri = URI(url)
    get "#{uri.path}?#{uri.query}", headers: @headers
  end

  def audit_row!(index)
    Lakeraven::EHR::AuditEvent.create!(
      event_type: "rest", action: "R", outcome: "0",
      entity_type: "Patient", entity_identifier: (index + 1).to_s
    )
  end

  def provenance_for!(dfn)
    Lakeraven::EHR::ProvenanceStore.instance.add(
      Lakeraven::EHR::Provenance.new(
        target_type: "Patient", target_id: "rpms-#{dfn}", activity: "CREATE",
        agent_who_id: "9001", agent_who_type: "Practitioner", recorded: Time.current
      )
    )
  end
end
