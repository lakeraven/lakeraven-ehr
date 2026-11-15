# frozen_string_literal: true

require "test_helper"

# #904 posture guard (slice of #522, 42 CFR Part 2): the December build has no
# route, screen or API that lets staff place an order, so none can order
# MAT/MOUD. Each test here goes red if an ordering pathway is re-added.
# Documenting substance use (notes, problems, screenings) is not ordering and
# is deliberately not matched.
class NoMatMoudOrderingPathwayTest < ActionDispatch::IntegrationTest
  ENGINE = "/lakeraven-ehr"
  ORDERING = /medication|order|prescri|erx|cpoe|ServiceRequest|MedicationDispense|MedicationAdministration|NutritionOrder|DeviceRequest|\brx\b|\bmeds?\b|refill|pharmac|dispens|script/i
  ORDER_TYPES = %w[MedicationRequest ServiceRequest MedicationDispense MedicationAdministration NutritionOrder DeviceRequest].freeze
  WRITE_INTERACTIONS = %w[create update patch delete].freeze
  ORDER_WRITE_RPCS = [ "ORWDX SAVE", "ORWDXC ACCEPT", "ORWDX SEND", "ORWDXA", "ORWDPS" ].freeze
  # Any quoted RPC name in the CPRS/RPMS order-write and outpatient-pharmacy families.
  ORDER_WRITE_RPC_NAME = /["'](?:ORWDX|ORWDPS|ORWOR1 SIG|APSP|BEHORX|PSO)[A-Z0-9 ]*["']/
  ORDERING_SERVICE_REFERENCE = /CpoeService|EprescribingService|Eprescribing::|NcpdpScriptGenerator|send_prescription|sign_and_release/
  # Amendment 3: every file under app/, lib/ and config/ is scanned. These
  # are exactly the files that name the ordering services today — no globs.
  # Adding a file here is a decision to open an ordering pathway: re-review
  # the MAT/MOUD refusals (#904) first.
  ORDERING_SERVICE_FILES = %w[
    app/services/lakeraven/ehr/cpoe_service.rb
    app/services/lakeraven/ehr/eprescribing/base_adapter.rb
    app/services/lakeraven/ehr/eprescribing/mock_adapter.rb
    app/services/lakeraven/ehr/eprescribing/not_configured_adapter.rb
    app/services/lakeraven/ehr/eprescribing_service.rb
    app/services/lakeraven/ehr/ncpdp_script_generator.rb
  ].freeze
  RPMS_ORDER_REFERENCE = %r{RpmsRpc::Order\b|rpms_rpc/api/order}
  RPMS_ORDER_FILES = %w[app/gateways/lakeraven/ehr/order_gateway.rb].freeze
  EPRESCRIBING_ADAPTER_FILES = %w[base_adapter eprescribing_adapter_factory mock_adapter not_configured_adapter transmission_result].freeze
  CPOE_SERVICE_API = %i[cancel_order create_imaging_order create_lab_order create_medication_order sign_order].freeze
  EPRESCRIBING_SERVICE_API = %i[approve_change approve_refill cancel check_status deny_change deny_refill request_change request_refill transmit].freeze
  ORDER_WRITE_CALLS = [
    /\bOrder\s*\.\s*(?:save|check|sign_and_release)\b/,
    /\b(?:via|default_provider)\s*\.\s*(?:save|check|sign_and_release)\b/
  ].freeze

  test "no route outside GET/HEAD reaches a medication or order surface" do
    offending = Lakeraven::EHR::Engine.routes.routes.select do |route|
      verbs = route.verb.to_s.split("|")
      writes = verbs.empty? || (verbs - %w[GET HEAD]).any?
      writes && (route.path.spec.to_s.match?(ORDERING) || route.defaults[:controller].to_s.match?(ORDERING))
    end

    assert_empty offending.map { |r| "#{r.verb} #{r.path.spec} => #{r.defaults[:controller]}##{r.defaults[:action]}" },
      "ordering write routes are not offered in the December build"
  end

  %w[MedicationRequest MedicationRequest/1 ServiceRequest ServiceRequest/1].each do |path|
    %i[post put patch delete].each do |verb|
      test "#{verb.upcase} /#{path} is not routable" do
        begin
          public_send(verb, "#{ENGINE}/#{path}", params: { resourceType: path.split("/").first }, as: :json)
        rescue ActionController::RoutingError
          next
        end
        assert_response :not_found
      end
    end
  end

  test "CapabilityStatement declares no write interaction for any order resource" do
    statement = Lakeraven::EHR::FHIR::CapabilityStatement
    document = statement.call(base_url: "https://ehr.example.test#{ENGINE}", token_endpoint: "https://ehr.example.test/oauth/token")
    served = document[:rest].flat_map { |rest| rest[:resource] }.to_h do |resource|
      [ resource[:type], resource[:interaction].map { |i| i[:code] } ]
    end

    ORDER_TYPES.each do |type|
      declared = Array(statement::RESOURCES.dig(type, :interactions)) | Array(served[type])
      assert_empty declared & WRITE_INTERACTIONS, "#{type} must stay read-only"
    end
  end

  test "no source file names an order-write RPC or calls an RpmsRpc::Order write method" do
    root = Lakeraven::EHR::Engine.root
    files = Dir[root.join("{app,lib}/**/*.{rb,erb,rake}").to_s]
    assert_operator files.size, :>, 100, "source scan found too few files to be trusted"

    hits = files.flat_map do |file|
      File.readlines(file).each_with_index.filter_map do |line, index|
        next unless ORDER_WRITE_RPCS.any? { |rpc| line.include?(rpc) } || line.match?(ORDER_WRITE_RPC_NAME) ||
          ORDER_WRITE_CALLS.any? { |call| line.match?(call) }

        "#{file.delete_prefix("#{root}/")}:#{index + 1}: #{line.strip}"
      end
    end

    assert_empty hits, "order writes (ORWDX SAVE / ORWDXC ACCEPT / ORWDX SEND) are not offered"
  end

  test "only the ordering services themselves name CPOE or e-prescribing anywhere in app, lib or config" do
    hits = source_references(ORDERING_SERVICE_REFERENCE)

    assert_equal ORDERING_SERVICE_FILES, hits.keys.sort & ORDERING_SERVICE_FILES,
      "an allowed file no longer names the ordering services: remove it from ORDERING_SERVICE_FILES"
    assert_empty hits.except(*ORDERING_SERVICE_FILES).values.flatten,
      "only the ordering services may name CpoeService, EprescribingService, Eprescribing::, NcpdpScriptGenerator, " \
      "send_prescription or sign_and_release (#904)"
  end

  test "only OrderGateway names RpmsRpc::Order anywhere in app, lib or config" do
    hits = source_references(RPMS_ORDER_REFERENCE)

    assert_equal RPMS_ORDER_FILES, hits.keys.sort & RPMS_ORDER_FILES,
      "an allowed file no longer names RpmsRpc::Order: remove it from RPMS_ORDER_FILES"
    assert_empty hits.except(*RPMS_ORDER_FILES).values.flatten,
      "RpmsRpc::Order (the order-write API) may be reached only through OrderGateway (#904)"
  end

  test "the e-prescribing adapters are exactly the known set" do
    adapters = Dir[Lakeraven::EHR::Engine.root.join("app/services/lakeraven/ehr/eprescribing/*.rb").to_s]

    assert_equal EPRESCRIBING_ADAPTER_FILES, adapters.map { |file| File.basename(file, ".rb") }.sort,
      "a pharmacy adapter was added or removed: re-review the MAT/MOUD refusals (#904) before changing this list"
  end

  test "the ordering services' public API is pinned" do
    assert_equal CPOE_SERVICE_API, Lakeraven::EHR::CpoeService.singleton_class.public_instance_methods(false).sort
    assert_equal EPRESCRIBING_SERVICE_API, Lakeraven::EHR::EprescribingService.public_instance_methods(false).sort
  end

  test "OrderGateway exposes only the read side of RpmsRpc::Order" do
    assert_equal %i[default_provider list unsigned_for_patient], Lakeraven::EHR::OrderGateway.singleton_methods(false).sort
  end

  private

  # { "relative/path" => [ "relative/path:line: text", ... ] } for every file
  # under app/ and lib/ (rb, erb, rake) and every file under config/ with a
  # line matching pattern.
  def source_references(pattern)
    root = Lakeraven::EHR::Engine.root
    files = Dir[root.join("{app,lib}/**/*.{rb,erb,rake}").to_s] + Dir[root.join("config/**/*").to_s].select { |f| File.file?(f) }
    assert_operator files.size, :>, 100, "source scan found too few files to be trusted"
    assert(files.any? { |f| f.start_with?(root.join("config").to_s) }, "source scan found no config files")

    files.uniq.each_with_object({}) do |file, hits|
      relative = file.delete_prefix("#{root}/")
      lines = File.readlines(file, encoding: "UTF-8").each_with_index.filter_map do |line, index|
        "#{relative}:#{index + 1}: #{line.strip}" if line.scrub.match?(pattern)
      end
      hits[relative] = lines if lines.any?
    end
  end
end
