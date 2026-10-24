# frozen_string_literal: true

require "test_helper"
require_relative "../dummy/lib/lakeraven_demo_seeds"

# Writes the FHIR JSON the engine serves, for the US Core validator.
#
# Not part of `bin/rails test` (the file name does not end in _test.rb).
# Run it on its own, then validate what it wrote:
#
#   US_CORE_SAMPLES_DIR=tmp/us-core-samples bin/rails test test/us_core/fhir_samples_export.rb
#   test/us_core/validate.rb tmp/us-core-samples
#
# Every read and search the CapabilityStatement declares is requested over
# HTTP against the demo seeds, so the samples are what a client receives, not
# what a serializer returns in isolation. Each search match is also written
# on its own, because a profile applies to a resource, not to the Bundle.
class USCoreSamplesExport < ActionDispatch::IntegrationTest
  include SmartAuthTestHelper

  ENGINE = "/lakeraven-ehr"

  # A read by id needs an id the seeds hold.
  READ_IDS = { "Practitioner" => "101", "ValueSet" => "us-core-sample" }.freeze

  setup do
    setup_smart_auth(scopes: "system/*.read")
    @dir = Pathname(ENV.fetch("US_CORE_SAMPLES_DIR", Rails.root.join("../../tmp/us-core-samples").to_s)).expand_path
    FileUtils.rm_rf(@dir)
    FileUtils.mkdir_p(@dir.join("resources"))

    RpmsRpc.mock! do |m|
      BASELINE_MOCK_SEEDS.call(m)
      LakeravenDemoSeeds.seed(m)
    end
    seed_beyond_the_demo_chart

    @valueset_dir = Dir.mktmpdir
    File.write(File.join(@valueset_dir, "us-core-sample.json"),
               { resourceType: "ValueSet", id: "us-core-sample", status: "active" }.to_json)
    @valueset_paths_were = Lakeraven::EHR::TerminologyService.additional_valueset_paths
    Lakeraven::EHR::TerminologyService.additional_valueset_paths = [ @valueset_dir ]
  end

  teardown do
    teardown_smart_auth
    RpmsRpc.mock!(&BASELINE_MOCK_SEEDS)
    Lakeraven::EHR::TerminologyService.additional_valueset_paths = @valueset_paths_were
    FileUtils.rm_rf(@valueset_dir)
  end

  test "export what every declared read and search serves" do
    get "#{ENGINE}/metadata"
    assert_response :ok
    write("metadata.json", response.body)

    manifest = declared_resources.flat_map { |type, interactions| export(type, interactions) }
    write("manifest.json", JSON.pretty_generate(manifest))

    assert manifest.any? { |sample| sample[:kind] == "resource" }, "no resource was exported"
  end

  private

  def declared_resources
    JSON.parse(File.read(@dir.join("metadata.json"))).dig("rest", 0, "resource").to_h do |resource|
      [ resource["type"], resource["interaction"].map { |i| i["code"] } ]
    end
  end

  def export(type, interactions)
    samples = []
    samples << fetch(type, "read", "#{ENGINE}/#{type}/#{read_id(type)}") if interactions.include?("read")
    samples.concat(search(type)) if interactions.include?("search-type")
    samples.compact
  end

  def read_id(type)
    type == "AuditEvent" ? @audit_event.id : READ_IDS.fetch(type, "1")
  end

  def fetch(type, interaction, path, params = {})
    get path, params: params, headers: @headers
    assert_response :ok, "#{interaction} #{type}: #{response.body}"

    file = "#{type}-#{interaction}.json"
    write(file, response.body)
    { kind: interaction == "read" ? "resource" : "bundle", type: type, file: file, request: request.fullpath }
  end

  def search(type)
    bundle = fetch(type, "search", "#{ENGINE}/#{type}", search_params(type))
    entries = JSON.parse(File.read(@dir.join(bundle[:file]))).fetch("entry", [])
    matches = entries.select { |entry| entry.dig("search", "mode") == "match" }

    resources = matches.each_with_index.map do |entry, index|
      file = "resources/#{type}-#{index + 1}.json"
      write(file, JSON.pretty_generate(entry["resource"]))
      { kind: "resource", type: type, file: file, request: bundle[:request] }
    end
    [ bundle, *resources ]
  end

  # Patient-compartment searches require the patient; the rest search
  # unfiltered, as a client listing the type would.
  def search_params(type)
    case type
    when "Patient" then { _id: "1" }
    when "Practitioner" then { name: "MARTINEZ" }
    when "AuditEvent" then { patient: "Patient/1" }
    when "Measure", "MeasureReport", "ValueSet" then {}
    else { patient: "1" }
    end
  end

  # The demo chart has no referrals and no audit trail: add one of each so
  # ServiceRequest and AuditEvent are sampled with content.
  def seed_beyond_the_demo_chart
    RpmsRpc.client.seed_keyed_collection(:referral_search, "1", [
      { ien: "1001", patient_dfn: 1, status: "active", type: "C",
        date: Date.new(2026, 1, 15), provider: "MARTINEZ,SARAH" }
    ])
    @audit_event = Lakeraven::EHR::AuditEvent.create!(event_type: "rest", action: "R", outcome: "0",
                                       entity_type: "Patient", entity_identifier: "1")
  end

  def write(file, body)
    File.write(@dir.join(file), body)
  end
end
