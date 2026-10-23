# frozen_string_literal: true

require "test_helper"

# GET /metadata (#574): the CapabilityStatement, checked against the routes
# and the wire in both directions. A capability it declares must work, and a
# routed type, interaction or search parameter that works must be declared.
# Every declaration is read from the served document, not from the Ruby map
# behind it.
class CapabilityStatementTest < ActionDispatch::IntegrationTest
  include SmartAuthTestHelper

  ENGINE = "/lakeraven-ehr"
  METADATA = "#{ENGINE}/metadata".freeze

  # Show routes that always answer 404: routed, so a client gets a FHIR
  # not-found rather than a routing error, but no read by id behind them.
  STUB_READS = %w[AllergyIntolerance Condition MedicationRequest Observation Consent].freeze

  # Measure/$import is routed but has no standard OperationDefinition to
  # name, so it is not declared.
  UNDECLARED_OPERATIONS = [ %w[Measure import] ].freeze

  # Baseline patients (test_helper): 1 Anderson,Alice F 1980-05-15;
  # 2 MOUSE,MICKEY M 2010-02-14; 3 DOE,JANE F 1990-12-25. Vitals for 1.
  SEARCH_PROBES = {
    %w[Patient _id] => lambda {
      assert_equal %w[2], search_ids("Patient", _id: "2")
      assert_empty search_ids("Patient", _id: "2", gender: "female"), "_id combines with the other parameters"
    },
    %w[Patient name] => lambda {
      ids = search_ids("Patient", name: "Anderson")
      assert_includes ids, "1"
      refute_includes ids, "2"
    },
    %w[Patient birthdate] => lambda {
      assert_equal %w[3], search_ids("Patient", birthdate: "1990-12-25")
      assert_refused("Patient", birthdate: "1990")
      assert_refused("Patient", birthdate: "ge1990-12-25")
    },
    %w[Patient gender] => lambda {
      assert_equal %w[2], search_ids("Patient", gender: "male")
      assert_equal %w[1 3], search_ids("Patient", gender: "female").sort
      assert_empty search_ids("Patient", gender: "other")
      assert_refused("Patient", gender: "M")
    },
    %w[Practitioner name] => lambda {
      ids = search_ids("Practitioner", name: "CHEN")
      assert_includes ids, "102"
      refute_includes ids, "101"
    },
    %w[Observation category] => lambda {
      refute_empty search_ids("Observation", patient: "1", category: "vital-signs")
      assert_empty search_ids("Observation", patient: "1", category: "laboratory")
      assert_refused("Observation", patient: "1",
                     category: "http://terminology.hl7.org/CodeSystem/observation-category|vital-signs")
    },
    %w[Observation code] => lambda {
      codes = search_resources("Observation", patient: "1", code: "8867-4,8310-5")
              .map { |r| r.dig("code", "coding", 0, "code") }
      assert_equal %w[8310-5 8867-4], codes.sort
      assert_refused("Observation", patient: "1", code: "http://loinc.org|8867-4")
    },
    %w[AuditEvent patient] => lambda {
      mine = Lakeraven::EHR::AuditEvent.create!(event_type: "rest", action: "R", outcome: "0",
                                                entity_type: "Patient", entity_identifier: "1")
      theirs = Lakeraven::EHR::AuditEvent.create!(event_type: "rest", action: "R", outcome: "0",
                                                  entity_type: "Patient", entity_identifier: "2")
      ids = search_ids("AuditEvent", patient: "Patient/1", _count: "100")
      assert_includes ids, mine.id.to_s
      refute_includes ids, theirs.id.to_s
    },
    %w[MedicationRequest status] => lambda {
      RpmsRpc.client.seed_text(:medication_active, "1", <<~WIRE)
        ~OP^1R;O^LISINOPRIL 10MG TAB^^3271231^3^^^120001^ACTIVE
        ~OP^2R;O^METFORMIN 500MG TAB^^3271231^1^^^120002^DISCONTINUED
      WIRE
      assert_equal %w[1R-O], search_ids("MedicationRequest", patient: "1", status: "active")
      assert_equal %w[2R-O], search_ids("MedicationRequest", patient: "1", status: "stopped")
      assert_refused("MedicationRequest", patient: "1", status: "http://hl7.org/fhir/CodeSystem/medicationrequest-status|active")
    }
  }.freeze

  # The patient compartment parameter: required, and it selects the patient.
  # Where the mock backend can hold a row for patient 1, patient 3 must not
  # see it.
  PATIENT_SEEDS = {
    "AllergyIntolerance" => [ :allergy_list, { allergen: "Penicillin", reaction: "Hives", severity: "moderate" } ],
    "Condition" => [ :problem_list, { ien: 11, status: "A", icd_code: "E11.9", description: "Type 2 diabetes" } ],
    "MedicationRequest" => [ :medication_active, "~OP^11R;O^METFORMIN 500MG TAB^^3271231^1^^^120011^ACTIVE\n" ],
    "Procedure" => [ :procedure_list, { ien: 7001, name: "Office visit", date: Date.new(2026, 3, 10),
                                        provider: "MARTINEZ,SARAH", status: "C" } ]
  }.freeze

  setup do
    setup_smart_auth(scopes: "system/*.*")
    # The engine ships no ValueSets: a host contributes them as JSON files.
    @valueset_dir = Dir.mktmpdir
    File.write(File.join(@valueset_dir, "capability-probe.json"),
               { resourceType: "ValueSet", id: "capability-probe", name: "CapabilityProbe", status: "active" }.to_json)
    @valueset_paths_were = Lakeraven::EHR::TerminologyService.additional_valueset_paths
    Lakeraven::EHR::TerminologyService.additional_valueset_paths = [ @valueset_dir ]
  end

  teardown do
    teardown_smart_auth
    Lakeraven::EHR::TerminologyService.additional_valueset_paths = @valueset_paths_were
    FileUtils.rm_rf(@valueset_dir)
    Lakeraven::EHR.configuration.token_endpoint_url = nil
  end

  test "metadata is a FHIR R4 CapabilityStatement, served without a token" do
    get METADATA

    assert_response :ok
    assert_equal "application/fhir+json", response.media_type
    assert_equal "CapabilityStatement", statement["resourceType"]
    assert_equal "4.0.1", statement["fhirVersion"]
    assert_equal "instance", statement["kind"]
    assert_equal "active", statement["status"]
    assert_equal Date.current.iso8601, statement["date"]
    assert_includes statement["format"], "json"
    assert_equal "server", rest["mode"]
    assert_equal "http://www.example.com#{ENGINE}", statement.dig("implementation", "url")
  end

  test "the in-process mock backend is disclosed as synthetic data" do
    get METADATA

    assert_includes statement.dig("implementation", "description"), "synthetic"
  end

  test "every routed FHIR type is declared, and every declared type is routed" do
    get METADATA

    assert_equal routed.keys.sort, declared_resources.keys.sort
  end

  test "the declared interactions are the routed ones, less the show stubs" do
    get METADATA

    routed.each do |type, routes|
      expected = []
      expected << "read" if routes.include?(:show) && STUB_READS.exclude?(type)
      expected << "search-type" if routes.include?(:index)
      expected << "create" if routes.include?(:create)
      declared = declared_resources.fetch(type).fetch("interaction").map { |i| i["code"] }

      assert_equal expected.sort, declared.sort, "#{type} interactions"
    end
  end

  test "the declared operations are the routed ones" do
    get METADATA

    routed_ops = routed.flat_map { |type, routes| routes.grep(Array).map { |(_, op)| [ type, op ] } }
    declared_ops = declared_resources.flat_map do |type, resource|
      Array(resource["operation"]).map { |op| [ type, op["name"] ] }
    end

    assert_equal (routed_ops - UNDECLARED_OPERATIONS).sort, declared_ops.sort
  end

  test "every declared read, search and create answers on the wire" do
    get METADATA
    resources = declared_resources

    resources.each do |type, resource|
      codes = resource["interaction"].map { |i| i["code"] }
      assert_read_works(type) if codes.include?("read")
      assert_search_works(type, resource) if codes.include?("search-type")
      assert_create_answers(type) if codes.include?("create")
    end
  end

  test "a show stub answers 404, which is why it declares no read" do
    STUB_READS.each do |type|
      get "#{ENGINE}/#{type}/1", headers: @headers

      assert_response :not_found
      assert_equal "OperationOutcome", JSON.parse(response.body)["resourceType"], type
    end
  end

  test "every declared search parameter has a probe here, and every probe is declared" do
    get METADATA

    declared = declared_resources.flat_map do |type, resource|
      Array(resource["searchParam"]).map { |param| [ type, param["name"] ] }.reject { |(_, name)| name == "_sort" }
    end
    probed = SEARCH_PROBES.keys + patient_compartment_types.map { |type| [ type, "patient" ] }

    assert_equal probed.sort, declared.sort
  end

  test "every declared search parameter is applied" do
    SEARCH_PROBES.each_value { |probe| instance_exec(&probe) }
  end

  test "the patient parameter is required and selects the patient" do
    PATIENT_SEEDS.each do |type, (collection, row)|
      if row.is_a?(String)
        RpmsRpc.client.seed_text(collection, "1", row)
      else
        RpmsRpc.client.seed_keyed_collection(collection, "1", [ row ])
      end
    end

    patient_compartment_types.each do |type|
      get "#{ENGINE}/#{type}", headers: @headers
      assert_response :bad_request, "#{type} without patient"

      search_ids(type, patient: "1")
      next unless PATIENT_SEEDS.key?(type)

      refute_empty search_resources(type, patient: "1"), "#{type}?patient=1"
      assert_empty search_resources(type, patient: "3"), "#{type}?patient=3"
    end
  end

  test "every declared _sort, _include and _revinclude is accepted, and others are refused" do
    get METADATA

    declared_resources.each do |type, resource|
      next unless resource["interaction"].any? { |i| i["code"] == "search-type" }

      base = search_params_for(type, resource)
      sort_names(resource).each { |name| search_ids(type, base.merge(_sort: "-#{name}")) }
      Array(resource["searchInclude"]).each { |value| search_ids(type, base.merge(_include: value)) }
      Array(resource["searchRevInclude"]).each { |value| search_ids(type, base.merge(_revinclude: value)) }

      assert_refused(type, base.merge(_sort: "undeclared"))
      assert_refused(type, base.merge(_include: "#{type}:undeclared"))
      assert_refused(type, base.merge(_revinclude: "Provenance:undeclared"))
    end
  end

  test "the parameters common to every search are declared at rest level" do
    get METADATA

    assert_equal %w[_count _offset _sort _include], rest["searchParam"].map { |param| param["name"] }
  end

  test "the token endpoint is the one smart-configuration publishes, under the engine mount" do
    token = metadata_token_endpoint

    get "#{ENGINE}/.well-known/smart-configuration"
    assert_equal JSON.parse(response.body)["token_endpoint"], token
    assert_equal "http://www.example.com#{ENGINE}/oauth/token", token

    route = Rails.application.routes.recognize_path(URI(token).path, method: :post)
    assert_equal "lakeraven/ehr/backend_services", route[:controller]
    assert_equal "token", route[:action]
  end

  test "the EHR launch response names the same token endpoint" do
    token = metadata_token_endpoint
    get "#{ENGINE}/smart/launch", params: { launch: "abc", iss: "https://ehr.example.test" }

    assert_equal token, JSON.parse(response.body)["token_endpoint"]
  end

  test "a configured token endpoint URL is the one every document publishes" do
    configured = "https://ehr.example.test/lakeraven-ehr/oauth/token"
    Lakeraven::EHR.configuration.token_endpoint_url = configured

    get "#{ENGINE}/.well-known/smart-configuration"
    assert_equal configured, JSON.parse(response.body)["token_endpoint"]
    assert_equal configured, metadata_token_endpoint
  end

  test "the security element names the SMART service and no scopes" do
    get METADATA
    security = rest.fetch("security")

    assert_equal "SMART-on-FHIR", security.dig("service", 0, "coding", 0, "code")
    refute_match %r{(?:patient|user|system)/}, security.to_json
  end

  private

  def statement
    JSON.parse(response.body)
  end

  def rest
    statement.fetch("rest").first
  end

  def declared_resources
    rest.fetch("resource").to_h { |resource| [ resource["type"], resource ] }
  end

  # { "Patient" => [:index, :show, :create], "ValueSet" => [..., [:op, "expand"]] }
  # from the engine's routes: every path whose first segment is a FHIR type.
  def routed
    Lakeraven::EHR::Engine.routes.routes.each_with_object(Hash.new { |h, k| h[k] = [] }) do |route, types|
      segments = route.path.spec.to_s.delete_suffix("(.:format)").split("/").reject(&:empty?)
      type = segments.first
      next unless type&.match?(/\A[A-Z][A-Za-z]+\z/)

      types[type] << route_kind(route.verb, segments.drop(1))
    end
  end

  def route_kind(verb, rest)
    operation = rest.find { |segment| segment.start_with?("$") }
    return [ :op, operation.delete_prefix("$") ] if operation
    return :show if verb == "GET" && rest.length == 1
    return :index if verb == "GET" && rest.empty?

    :create if verb == "POST" && rest.empty?
  end

  def patient_compartment_types
    %w[AllergyIntolerance Condition MedicationRequest Observation Encounter ServiceRequest Immunization
       Procedure Consent]
  end

  def search_params_for(type, resource)
    required = Array(resource["searchParam"]).any? do |param|
      param["name"] == "patient" && param["documentation"].start_with?("Required")
    end
    required ? { patient: "1" } : {}
  end

  def sort_names(resource)
    sort = Array(resource["searchParam"]).find { |param| param["name"] == "_sort" }
    return [] unless sort

    sort["documentation"][/Sorts on: (.*?)\. /, 1].split(", ")
  end

  def search_resources(type, params)
    get "#{ENGINE}/#{type}", params: params, headers: @headers
    assert_response :ok, "#{type}?#{params.to_query}: #{response.body}"
    bundle = JSON.parse(response.body)
    assert_equal "searchset", bundle["type"]
    bundle.fetch("entry", []).select { |e| e.dig("search", "mode") == "match" }.map { |e| e["resource"] }
  end

  def search_ids(type, params)
    search_resources(type, params).map { |resource| resource["id"].to_s }
  end

  def assert_refused(type, params)
    get "#{ENGINE}/#{type}", params: params, headers: @headers

    assert_response :bad_request, "#{type}?#{params.to_query}"
    assert_equal "OperationOutcome", JSON.parse(response.body)["resourceType"]
  end

  def assert_read_works(type)
    get "#{ENGINE}/#{type}/#{read_probe_id(type)}", headers: @headers

    assert_response :ok, "#{type} read: #{response.body}"
    assert_equal type, JSON.parse(response.body)["resourceType"]
  end

  def read_probe_id(type)
    case type
    when "Practitioner" then "101"
    when "AuditEvent"
      Lakeraven::EHR::AuditEvent.create!(event_type: "rest", action: "R", outcome: "0",
                                         entity_type: "Patient", entity_identifier: "1").id
    when "ValueSet" then "capability-probe"
    else "1"
    end
  end

  def assert_search_works(type, resource)
    search_resources(type, search_params_for(type, resource))
  end

  # Reaching the handler is what the route table cannot show: an empty body
  # is refused by the action itself, not by routing.
  def assert_create_answers(type)
    post "#{ENGINE}/#{type}", params: "{}", headers: @headers.merge("Content-Type" => "application/fhir+json")

    assert_includes [ 400, 422 ], response.status, "#{type} create: #{response.body}"
    assert_equal "OperationOutcome", JSON.parse(response.body)["resourceType"]
  end

  def metadata_token_endpoint
    get METADATA
    oauth = rest.dig("security", "extension").find do |extension|
      extension["url"] == "http://fhir-registry.smarthealthit.org/StructureDefinition/oauth-uris"
    end
    oauth.fetch("extension").find { |extension| extension["url"] == "token" }.fetch("valueUri")
  end
end
