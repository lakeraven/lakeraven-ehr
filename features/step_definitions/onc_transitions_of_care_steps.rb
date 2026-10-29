# frozen_string_literal: true

# ONC § 170.315(b)(1) — Transitions of Care step definitions
# Covers C-CDA generation, round-trip validation, and performance.
#
# Shared steps NOT redefined here:
#   "a patient exists with DFN {string}" — cpoe_steps.rb
#   "the generation should complete in under {int} seconds" — electronic_prescribing_steps.rb

require_relative "../../test/support/ccda_model_fixtures"

World(Lakeraven::EHR::CcdaModelFixtures)

# -----------------------------------------------------------------------------
# Given: patient with clinical data for C-CDA generation
# -----------------------------------------------------------------------------

Given("the patient has no address on file for a care summary") do
  dfn = (@patient_dfn || Lakeraven::EHR::CcdaModelFixtures::SYNTHETIC_DFN).to_s
  @care_summary_data = {
    patient: synthetic_patient(
      dfn: dfn.to_i,
      name: "TEST,PATIENT ONE",
      address_line1: nil,
      city: nil,
      state: nil,
      zip_code: nil
    ),
    allergies: [],
    conditions: [],
    medications: [],
    vitals: [],
    encounters: [],
    author: synthetic_author
  }
end

Given("the Part 2 egress filter rewrites the patient dfn to {string}") do |rewritten_dfn|
  @egress_filter_impl = ->(sections) {
    sections.merge(patient: sections[:patient].merge(dfn: rewritten_dfn))
  }
end

When("a transitions of care document is requested for the patient") do
  dfn = @patient_dfn || "1"
  patient = Lakeraven::EHR::Patient.new(
    dfn: dfn.to_i,
    name: "Anderson,Alice",
    dob: Date.parse("1980-05-15"),
    sex: "F"
  )
  stub_gateway(Lakeraven::EHR::Patient, :find_by_dfn, patient)

  app = Doorkeeper::Application.create!(
    name: "toc-spec-#{SecureRandom.hex(4)}",
    redirect_uri: "https://example.test/callback",
    scopes: "system/*.read system/*.write",
    confidential: true
  )
  token = Doorkeeper::AccessToken.create!(
    application: app,
    scopes: "system/*.read system/*.write",
    expires_in: 3600
  )
  header "Authorization", "Bearer #{token.plaintext_token || token.token}"

  filter = Lakeraven::EHR::Part2EgressFilter.singleton_class
  original = filter.instance_method(:call)
  filter.define_method(:call, &@egress_filter_impl)
  begin
    post "/lakeraven-ehr/transitions_of_care", params: { patient_dfn: dfn }
    @transitions_of_care_response = last_response
  ensure
    filter.define_method(:call, original)
  end
end

Then("the transitions of care response should refuse egress with status {int}") do |status|
  assert_equal status, @transitions_of_care_response.status
  refute_includes @transitions_of_care_response.body, "ClinicalDocument"
  assert_includes @transitions_of_care_response.body, "Part 2 egress filter did not return clinical sections"
end

Then("the transitions of care response should include C-CDA with patient id extension {string}") do |extension|
  assert_equal 201, @transitions_of_care_response.status
  assert_includes @transitions_of_care_response.body, "ClinicalDocument"
  doc = Nokogiri::XML(@transitions_of_care_response.body)
  actual = doc.at_xpath(
    "//xmlns:patientRole/xmlns:id/@extension",
    "xmlns" => "urn:hl7-org:v3"
  )&.value
  assert_equal extension, actual,
    "Expected patientRole id extension #{extension.inspect}, got #{actual.inspect}"
end

Then("the document should omit patient addr") do
  refute @ccda_doc.at_xpath("//xmlns:patientRole/xmlns:addr", "xmlns" => "urn:hl7-org:v3"),
    "Expected no patient addr when all address fields are blank"
end

Then("the encounters section should follow CDA element order") do
  ns = { "xmlns" => "urn:hl7-org:v3" }
  section = @ccda_doc.at_xpath(
    "//xmlns:section[xmlns:templateId[@root='2.16.840.1.113883.10.20.22.2.22.1']]",
    ns
  )
  assert section.present?, "Expected encounters section"

  names = section.element_children.map(&:name)
  template_idx = names.index("templateId")
  code_idx = names.index("code")
  title_idx = names.index("title")
  assert template_idx && code_idx && title_idx
  assert template_idx < code_idx && code_idx < title_idx,
    "expected templateId, code, title in order; got #{names.inspect}"

  section_code = section.at_xpath("./xmlns:code", ns)
  assert_equal "46240-8", section_code&.[]("code")
end

Given("the patient has clinical data for a care summary") do
  dfn = (@patient_dfn || Lakeraven::EHR::CcdaModelFixtures::SYNTHETIC_DFN).to_s
  @care_summary_data = {
    patient: synthetic_patient(dfn: dfn.to_i, name: "TEST,PATIENT ONE"),
    allergies: synthetic_allergies.map { |a| a.tap { |row| row.patient_dfn = dfn } },
    conditions: synthetic_conditions.map { |c| c.tap { |row| row.patient_dfn = dfn } },
    medications: synthetic_medications.map { |m| m.tap { |row| row.patient_dfn = dfn } },
    vitals: synthetic_vitals.map { |v| v.tap { |row| row.patient_dfn = dfn } },
    encounters: synthetic_encounters.map { |e| e.tap { |row| row.patient_dfn = dfn.to_i } },
    author: synthetic_author.merge(institution: "Example Health Center")
  }
end

# -----------------------------------------------------------------------------
# When: generate C-CDA
# -----------------------------------------------------------------------------

When("a C-CDA document is generated for the patient") do
  @generated_ccda = Lakeraven::EHR::CcdaGenerator.generate(**@care_summary_data)
  @ccda_doc = Nokogiri::XML(@generated_ccda)
end

When("the generated document is parsed by CcdaParser") do
  @parsed_result = Lakeraven::EHR::CcdaParser.new.parse(@generated_ccda)
end

When("a C-CDA document is generated with timing") do
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  @generated_ccda = Lakeraven::EHR::CcdaGenerator.generate(**@care_summary_data)
  @generation_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
end

# -----------------------------------------------------------------------------
# Then: document structure
# -----------------------------------------------------------------------------

Then("the document should be valid XML") do
  doc = Nokogiri::XML(@generated_ccda) { |config| config.strict }
  assert doc.errors.empty?, "Expected valid XML, got errors: #{doc.errors.map(&:message)}"
end

Then("the document should have CCD template ID {string}") do |template_id|
  templates = @ccda_doc.xpath("//xmlns:templateId/@root", "xmlns" => "urn:hl7-org:v3").map(&:value)
  assert_includes templates, template_id, "Expected CCD template ID #{template_id}"
end

Then("the document should include the patient demographics") do
  given = @ccda_doc.at_xpath("//xmlns:patient/xmlns:name/xmlns:given", "xmlns" => "urn:hl7-org:v3")
  assert given&.text.present?, "Expected patient given name"
  family = @ccda_doc.at_xpath("//xmlns:patient/xmlns:name/xmlns:family", "xmlns" => "urn:hl7-org:v3")
  assert family&.text.present?, "Expected patient family name"
end

# -----------------------------------------------------------------------------
# Then: clinical sections
# -----------------------------------------------------------------------------

Then("the document should include an allergies section") do
  section = @ccda_doc.at_xpath(
    "//xmlns:section[xmlns:templateId[@root='2.16.840.1.113883.10.20.22.2.6.1']]",
    "xmlns" => "urn:hl7-org:v3"
  )
  assert section.present?, "Expected allergies section"
end

Then("the allergies section should contain coded entries") do
  entries = @ccda_doc.xpath(
    "//xmlns:section[xmlns:templateId[@root='2.16.840.1.113883.10.20.22.2.6.1']]//xmlns:entry",
    "xmlns" => "urn:hl7-org:v3"
  )
  assert entries.any?, "Expected coded allergy entries"
end

Then("the document should include a problems section") do
  section = @ccda_doc.at_xpath(
    "//xmlns:section[xmlns:templateId[@root='2.16.840.1.113883.10.20.22.2.5.1']]",
    "xmlns" => "urn:hl7-org:v3"
  )
  assert section.present?, "Expected problems section"
end

Then("the problems section should contain coded entries") do
  entries = @ccda_doc.xpath(
    "//xmlns:section[xmlns:templateId[@root='2.16.840.1.113883.10.20.22.2.5.1']]//xmlns:entry",
    "xmlns" => "urn:hl7-org:v3"
  )
  assert entries.any?, "Expected coded problem entries"
end

Then("the document should include a medications section") do
  section = @ccda_doc.at_xpath(
    "//xmlns:section[xmlns:templateId[@root='2.16.840.1.113883.10.20.22.2.1.1']]",
    "xmlns" => "urn:hl7-org:v3"
  )
  assert section.present?, "Expected medications section"
end

Then("the medications section should contain coded entries") do
  entries = @ccda_doc.xpath(
    "//xmlns:section[xmlns:templateId[@root='2.16.840.1.113883.10.20.22.2.1.1']]//xmlns:entry",
    "xmlns" => "urn:hl7-org:v3"
  )
  assert entries.any?, "Expected coded medication entries"
end

Then("the document should include a vital signs section") do
  section = @ccda_doc.at_xpath(
    "//xmlns:section[xmlns:templateId[@root='2.16.840.1.113883.10.20.22.2.4.1']]",
    "xmlns" => "urn:hl7-org:v3"
  )
  assert section.present?, "Expected vital signs section"
end

Then("the document should include an encounters section") do
  section = @ccda_doc.at_xpath(
    "//xmlns:section[xmlns:templateId[@root='2.16.840.1.113883.10.20.22.2.22.1']]",
    "xmlns" => "urn:hl7-org:v3"
  )
  assert section.present?, "Expected encounters section"
end

# -----------------------------------------------------------------------------
# Then: round-trip validation
# -----------------------------------------------------------------------------

Then("the parsed allergies should match the patient allergies") do
  assert_equal 2, @parsed_result[:allergies].length,
    "Expected 2 allergies from round-trip, got #{@parsed_result[:allergies].length}"
end

Then("the parsed conditions should match the patient conditions") do
  assert_equal 2, @parsed_result[:conditions].length,
    "Expected 2 conditions from round-trip, got #{@parsed_result[:conditions].length}"
end

Then("the parsed medications should match the patient medications") do
  assert_equal 2, @parsed_result[:medications].length,
    "Expected 2 medications from round-trip, got #{@parsed_result[:medications].length}"
end

# -----------------------------------------------------------------------------
# Then: metadata
# -----------------------------------------------------------------------------

Then("the document should include an author section") do
  author = @ccda_doc.at_xpath("//xmlns:author", "xmlns" => "urn:hl7-org:v3")
  assert author.present?, "Expected author in document"
end

Then("the document should include a custodian section") do
  custodian = @ccda_doc.at_xpath("//xmlns:custodian", "xmlns" => "urn:hl7-org:v3")
  assert custodian.present?, "Expected custodian in document"
end

Then("the document type code should be {string} for Summarization of Episode Note") do |code|
  doc_code = @ccda_doc.at_xpath("//xmlns:code/@code", "xmlns" => "urn:hl7-org:v3")
  assert_equal code, doc_code&.value, "Expected document type code #{code}"
end
