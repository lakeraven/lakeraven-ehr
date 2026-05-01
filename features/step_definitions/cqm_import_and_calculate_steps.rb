# frozen_string_literal: true

# ONC 170.315(c)(2) — CQM Import and Calculate step definitions — lakeraven-ehr
#
# Reuses from cqm_steps.rb:
#   - "patient {string} has a condition with code..."
#   - "patient {string} has an observation with code..."
#   - "the system is configured for FHIR API access"
#   - "I have a valid SMART token with scope {string}"
#   - "the response should be a FHIR Bundle"
# Reuses from bulk_export_steps.rb:
#   - "the response status should be {int}"

# Track imported measure YAML files for cleanup
Before("@onc") do
  @imported_measure_files = []
end

After do
  (@imported_measure_files || []).each { |f| FileUtils.rm_f(f) }
end

# "the following patients exist:" defined in drug_interaction_steps.rb

# -----------------------------------------------------------------------------
# When: import measures
# -----------------------------------------------------------------------------

When("a FHIR Measure resource is imported with:") do |table|
  data = table.rows_hash
  @import_fhir_measure = build_test_fhir_measure(
    id: data["id"],
    title: data["title"],
    nqf_number: data["nqf_number"],
    scoring: data["scoring"] || "proportion"
  )
  track_imported_measure(data["id"])

  service = Lakeraven::EHR::MeasureImportService.new
  @import_result = service.import_from_resource(@import_fhir_measure)
end

When("a FHIR Bundle is imported containing measures:") do |table|
  entries = table.hashes.map do |row|
    track_imported_measure(row["id"])
    { "resource" => build_test_fhir_measure(
      id: row["id"],
      title: row["title"],
      nqf_number: row["nqf_number"],
      scoring: "proportion"
    ) }
  end

  bundle = {
    "resourceType" => "Bundle",
    "type" => "collection",
    "entry" => entries
  }

  service = Lakeraven::EHR::MeasureImportService.new
  @import_results = service.import_from_bundle(bundle.to_json)
end

When("an invalid FHIR Measure resource is imported") do
  service = Lakeraven::EHR::MeasureImportService.new
  @import_result = service.import_from_resource({ "resourceType" => "Measure" })
end

When("data requirements are requested for measure {string}") do |measure_id|
  service = Lakeraven::EHR::MeasureImportService.new
  @data_requirements = service.data_requirements(measure_id)
end

When("measure {string} is calculated for patient {string} for period {string} to {string}") do |measure_id, dfn, start_date, end_date|
  service = Lakeraven::EHR::CqmCalculationService.new(
    conditions: @conditions || [],
    observations: @observations || []
  )
  period = Date.parse(start_date)..Date.parse(end_date)
  @calc_report = service.evaluate(measure_id, dfn, period: period)
end

When("measure {string} is calculated for patients {string} for period {string} to {string}") do |measure_id, dfns_str, start_date, end_date|
  service = Lakeraven::EHR::CqmCalculationService.new(
    conditions: @conditions || [],
    observations: @observations || []
  )
  period = Date.parse(start_date)..Date.parse(end_date)
  patient_dfns = dfns_str.split(",").map(&:strip)
  @calc_summary = service.evaluate_population(measure_id, patient_dfns, period: period)
end

# FHIR API import
When("I POST a FHIR Measure resource to {string}") do |path|
  measure = build_test_fhir_measure(
    id: "test_api_import",
    title: "API Import Test Measure",
    nqf_number: "9999",
    scoring: "proportion"
  )
  track_imported_measure("test_api_import")

  url = path.sub("/fhir/", "/lakeraven-ehr/")
  header "Authorization", @fhir_headers["Authorization"]
  header "Content-Type", "application/fhir+json"
  post url, measure.to_json
end

When("a FHIR Measure resource is imported with timing") do
  measure = build_test_fhir_measure(
    id: "test_timing_import",
    title: "Timing Test",
    nqf_number: "0000",
    scoring: "proportion"
  )
  track_imported_measure("test_timing_import")

  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  service = Lakeraven::EHR::MeasureImportService.new
  @import_result = service.import_from_resource(measure)
  @import_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
end

# -----------------------------------------------------------------------------
# Then: import assertions
# -----------------------------------------------------------------------------

Then("the import should succeed") do
  assert @import_result.success?, "Expected import to succeed: #{@import_result.errors.join(', ')}"
end

Then("the import should fail with validation errors") do
  refute @import_result.success?, "Expected import to fail"
  assert @import_result.errors.any?, "Expected validation errors"
end

Then("{int} measures should be imported successfully") do |count|
  successful = @import_results.select(&:success?)
  assert_equal count, successful.count,
    "Expected #{count} successful imports, got #{successful.count}"
end

Then("measure {string} should be available in the system") do |measure_id|
  measure = Lakeraven::EHR::Measure.find(measure_id)
  refute_nil measure, "Expected measure '#{measure_id}' to be available"
end

Then("measure {string} should have NQF number {string}") do |measure_id, nqf|
  measure = Lakeraven::EHR::Measure.find(measure_id)
  assert_equal nqf, measure.nqf_number
end

# -----------------------------------------------------------------------------
# Then: data requirements assertions
# -----------------------------------------------------------------------------

Then("the data requirements should list referenced ValueSets") do
  assert @data_requirements.present?, "Expected data requirements"
  assert @data_requirements.any?, "Expected at least one data requirement"
end

Then("each data requirement should include a canonical URL") do
  @data_requirements.each do |req|
    assert req[:canonical_url].present?,
      "Expected canonical URL for requirement #{req[:id]}"
  end
end

Then("each data requirement should indicate local availability") do
  @data_requirements.each do |req|
    assert [ true, false ].include?(req[:available]),
      "Expected boolean availability for requirement #{req[:id]}"
  end
end

# -----------------------------------------------------------------------------
# Then: calculation assertions
# -----------------------------------------------------------------------------

Then("the calculation should produce a MeasureReport") do
  refute_nil @calc_report, "Expected a MeasureReport"
  assert_equal "individual", @calc_report.report_type
end

Then("the MeasureReport should show the patient in the initial population") do
  assert_equal 1, @calc_report.initial_population_count,
    "Expected patient in initial population"
end

Then("the MeasureReport should show the patient in the numerator") do
  assert_equal 1, @calc_report.numerator_count,
    "Expected patient in numerator"
end

Then("the calculation should produce a summary MeasureReport") do
  refute_nil @calc_summary, "Expected a summary MeasureReport"
  assert_equal "summary", @calc_summary.report_type
end

Then("the summary should show initial population count of {int}") do |count|
  assert_equal count, @calc_summary.initial_population_count
end

Then("the summary should show numerator count of {int}") do |count|
  assert_equal count, @calc_summary.numerator_count
end

Then("the summary should have a performance rate of {float}") do |rate|
  assert_in_delta rate, @calc_summary.performance_rate, 0.001
end

# -----------------------------------------------------------------------------
# Then: API assertions
# -----------------------------------------------------------------------------

Then("the response should be a FHIR OperationOutcome with success") do
  body = JSON.parse(last_response.body)
  assert_equal "OperationOutcome", body["resourceType"]
  issue = body["issue"]&.first
  assert issue.present?, "Expected issue in OperationOutcome"
  assert_includes %w[information warning], issue["severity"]
end

# -----------------------------------------------------------------------------
# Then: performance
# -----------------------------------------------------------------------------

Then("the import should complete within {int} seconds") do |seconds|
  assert @import_elapsed < seconds.to_f,
    "Import took #{@import_elapsed}s, expected < #{seconds}s"
end

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

def build_test_fhir_measure(id:, title:, nqf_number: nil, scoring: "proportion")
  measure = {
    "resourceType" => "Measure",
    "id" => id,
    "title" => title,
    "status" => "active",
    "scoring" => {
      "coding" => [ { "system" => "http://terminology.hl7.org/CodeSystem/measure-scoring",
                      "code" => scoring } ]
    }
  }

  if nqf_number
    measure["identifier"] = [ {
      "system" => "http://hl7.org/fhir/cqi/ecqm/Measure/Identifier/nqf",
      "value" => nqf_number
    } ]
  end

  measure
end

def track_imported_measure(measure_id)
  @imported_measure_files ||= []
  @imported_measure_files << Lakeraven::EHR::Engine.root.join("config", "measures", "#{measure_id}.yml").to_s
end
