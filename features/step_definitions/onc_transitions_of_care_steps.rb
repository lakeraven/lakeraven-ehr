# frozen_string_literal: true

# ONC § 170.315(b)(1) — Transitions of Care step definitions
# Covers C-CDA generation, round-trip validation, and performance.
#
# Shared steps NOT redefined here:
#   "a patient exists with DFN {string}" — cpoe_steps.rb
#   "the generation should complete in under {int} seconds" — electronic_prescribing_steps.rb

# -----------------------------------------------------------------------------
# Given: patient with clinical data for C-CDA generation
# -----------------------------------------------------------------------------

Given("the patient has clinical data for a care summary") do
  @care_summary_data = {
    patient: {
      dfn: @patient_dfn || "12345",
      name: { given: "Alice", family: "Anderson" },
      dob: "1975-06-15", sex: "F",
      address: { street: "123 Main St", city: "Anchorage", state: "AK", zip: "99501" }
    },
    allergies: [
      { code: "7980", code_system: "2.16.840.1.113883.6.88", display: "Penicillin", status: "active" },
      { code: "36567", code_system: "2.16.840.1.113883.6.88", display: "Simvastatin", status: "active" }
    ],
    conditions: [
      { code: "E11.9", code_system: "2.16.840.1.113883.6.90", display: "Type 2 diabetes mellitus", status: "active" },
      { code: "I10", code_system: "2.16.840.1.113883.6.90", display: "Essential hypertension", status: "active" }
    ],
    medications: [
      { code: "311364", code_system: "2.16.840.1.113883.6.88", display: "Lisinopril 10 MG Oral Tablet" },
      { code: "860975", code_system: "2.16.840.1.113883.6.88", display: "Metformin 500 MG Oral Tablet" }
    ],
    vitals: [
      { code: "8480-6", display: "Systolic BP", value: "120", units: "mm[Hg]", date: "2026-03-01" }
    ],
    encounters: [
      { date: "2026-03-01", type_code: "99213", type_display: "Office visit", performer: "Dr. Smith" }
    ],
    author: { name: "Dr. Smith", institution: "IHS Anchorage Facility" }
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
