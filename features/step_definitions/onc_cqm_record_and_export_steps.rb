# frozen_string_literal: true

# ONC § 170.315(c)(1) — CQM Record and Export step definitions
# Covers supported measures documentation, QRDA I/III export, and FHIR export.
#
# Shared steps NOT redefined here:
#   "the following patients exist:" — drug_interaction_steps.rb
#   "patient {string} has a condition with code {string} in valueset {string}" — cqm_steps.rb
#   "patient {string} has an observation with code {string} and value {float} recorded on {string}" — cqm_steps.rb
#   "I evaluate measure {string} for patient {string} for period {string} to {string}" — cqm_steps.rb
#   "the system is configured for FHIR API access" — cqm_steps.rb
#   "I have a valid SMART token with scope {string}" — cqm_steps.rb
#   "I request {string} with FHIR headers" — cqm_steps.rb
#   "the measure report should show initial population count of {int}" — cqm_steps.rb
#   "the measure report should show numerator count of {int}" — cqm_steps.rb
#   "the response should be a FHIR Bundle" — cqm_steps.rb
#   "the bundle should contain a MeasureReport with population groups" — cqm_steps.rb

# -----------------------------------------------------------------------------
# When: supported measures
# -----------------------------------------------------------------------------

When("the supported measures list is loaded") do
  @supported_measures = Lakeraven::EHR::Measure.all
end

# -----------------------------------------------------------------------------
# Then: supported measures assertions
# -----------------------------------------------------------------------------

Then("the list should include measure {string} with NQF {string}") do |measure_id, nqf|
  measure = @supported_measures.find { |m| m.id == measure_id }
  assert measure.present?, "Expected measure #{measure_id}"
  assert_equal nqf, measure.nqf_number, "Expected NQF #{nqf} for #{measure_id}"
end

Then("each measure should have population criteria defined") do
  @supported_measures.each do |measure|
    assert measure.initial_population.present?,
      "Expected initial_population for #{measure.id}"
    assert measure.numerator.present?,
      "Expected numerator for #{measure.id}"
  end
end

# -----------------------------------------------------------------------------
# When: QRDA Category I export
# -----------------------------------------------------------------------------

When("I export a QRDA Category I for patient {string} and measure {string} for period {string} to {string}") do |dfn, measure_id, start_date, end_date|
  service = Lakeraven::EHR::CqmCalculationService.new(
    conditions: @conditions || [],
    observations: @observations || []
  )
  period = Date.parse(start_date)..Date.parse(end_date)
  report = service.evaluate(measure_id, dfn, period: period)

  @qrda_i = Lakeraven::EHR::Qrda::CategoryOneExporter.generate(
    measure_report: report,
    patient: build_qrda_patient(dfn),
    conditions: @conditions || [],
    observations: @observations || []
  )
end

When("I export a QRDA Category I with timing for patient {string} and measure {string} for period {string} to {string}") do |dfn, measure_id, start_date, end_date|
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  service = Lakeraven::EHR::CqmCalculationService.new(
    conditions: @conditions || [],
    observations: @observations || []
  )
  period = Date.parse(start_date)..Date.parse(end_date)
  report = service.evaluate(measure_id, dfn, period: period)

  @qrda_i = Lakeraven::EHR::Qrda::CategoryOneExporter.generate(
    measure_report: report,
    patient: build_qrda_patient(dfn),
    conditions: @conditions || [],
    observations: @observations || []
  )
  @qrda_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
end

# -----------------------------------------------------------------------------
# Then: QRDA Category I assertions
# -----------------------------------------------------------------------------

Then("the QRDA I document should be valid XML") do
  doc = Nokogiri::XML(@qrda_i) { |config| config.strict }
  assert doc.errors.empty?, "QRDA I XML parse errors: #{doc.errors.join(', ')}"
end

Then("the QRDA I should contain the QRDA I template ID") do
  doc = Nokogiri::XML(@qrda_i)
  template_ids = doc.xpath("//*[local-name()='templateId']").map { |t| t["root"] }
  assert template_ids.include?("2.16.840.1.113883.10.20.24.1.1"),
    "Expected QRDA I template ID 2.16.840.1.113883.10.20.24.1.1"
end

Then("the QRDA I should contain the patient demographics") do
  doc = Nokogiri::XML(@qrda_i)
  record_target = doc.at_xpath("//*[local-name()='recordTarget']")
  assert record_target.present?, "Expected recordTarget element"

  patient_name = doc.at_xpath("//*[local-name()='recordTarget']//*[local-name()='name']")
  assert patient_name.present?, "Expected patient name in recordTarget"
end

Then("the QRDA I should contain the measure reference for NQF {string}") do |nqf|
  assert @qrda_i.include?(nqf), "Expected NQF #{nqf} in QRDA I"
end

Then("the QRDA I should contain population criteria results") do
  doc = Nokogiri::XML(@qrda_i)
  entries = doc.xpath("//*[local-name()='entry']")
  assert entries.any?, "Expected entry elements with population criteria"
end

Then("the QRDA I should contain a lab result entry with LOINC {string}") do |loinc_code|
  assert @qrda_i.include?(loinc_code),
    "Expected LOINC #{loinc_code} in QRDA I"
end

Then("the QRDA I should contain a condition entry with code {string}") do |code|
  assert @qrda_i.include?(code),
    "Expected condition code #{code} in QRDA I"
end

Then("the QRDA export should complete within {int} seconds") do |seconds|
  assert @qrda_elapsed < seconds.to_f,
    "QRDA export took #{@qrda_elapsed}s, expected < #{seconds}s"
end

# -----------------------------------------------------------------------------
# When: QRDA Category III export
# -----------------------------------------------------------------------------

When("I export a QRDA Category III for measure {string} for patients {string} for period {string} to {string}") do |measure_id, dfns_str, start_date, end_date|
  service = Lakeraven::EHR::CqmCalculationService.new(
    conditions: @conditions || [],
    observations: @observations || []
  )
  period = Date.parse(start_date)..Date.parse(end_date)
  patient_dfns = dfns_str.split(",").map(&:strip)
  summary_report = service.evaluate_population(measure_id, patient_dfns, period: period)

  @qrda_iii = Lakeraven::EHR::Qrda::CategoryThreeExporter.generate(
    measure_report: summary_report
  )
end

# -----------------------------------------------------------------------------
# Then: QRDA Category III assertions
# -----------------------------------------------------------------------------

Then("the QRDA III document should be valid XML") do
  doc = Nokogiri::XML(@qrda_iii) { |config| config.strict }
  assert doc.errors.empty?, "QRDA III XML parse errors: #{doc.errors.join(', ')}"
end

Then("the QRDA III should contain the QRDA III template ID") do
  doc = Nokogiri::XML(@qrda_iii)
  template_ids = doc.xpath("//*[local-name()='templateId']").map { |t| t["root"] }
  assert template_ids.include?("2.16.840.1.113883.10.20.27.1.1"),
    "Expected QRDA III template ID 2.16.840.1.113883.10.20.27.1.1"
end

Then("the QRDA III should contain the measure reference for NQF {string}") do |nqf|
  assert @qrda_iii.include?(nqf), "Expected NQF #{nqf} in QRDA III"
end

Then("the QRDA III should contain aggregate population counts") do
  doc = Nokogiri::XML(@qrda_iii)
  observations = doc.xpath("//*[local-name()='observation']")
  assert observations.any?, "Expected observation elements with population counts"
end

Then("the QRDA III should show a performance rate") do
  doc = Nokogiri::XML(@qrda_iii)
  perf_obs = doc.xpath("//*[local-name()='observation']").find do |obs|
    obs.xpath(".//*[local-name()='templateId']").any? { |t| t["root"] == "2.16.840.1.113883.10.20.27.3.14" }
  end
  assert perf_obs.present?, "Expected performance rate observation with template 2.16.840.1.113883.10.20.27.3.14"
end

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

def build_qrda_patient(dfn)
  case dfn
  when "1"
    { dfn: "1", name: { given: "Alice", family: "Anderson" },
      dob: "1980-05-15", sex: "F" }
  when "2"
    { dfn: "2", name: { given: "Bob", family: "Brown" },
      dob: "1975-08-20", sex: "M" }
  else
    { dfn: dfn, name: { given: "Test", family: "Patient" },
      dob: "1990-01-01", sex: "U" }
  end
end
