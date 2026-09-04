# frozen_string_literal: true

# Vardana clinical-data conformance steps (source-system profile v1,
# §3/§4/§5 + checklist items 3-10). Auth steps (items 1-2) live with the
# parallel auth work.
#
# Observation gateway rows use the REAL decorated-measurement shape the
# rpms-rpc Measurement reads return (rpms-rpc PR #188 — Measurement
# .history/.find over ORQQVI VITALS + DDR GETS ENTRY DATA + BEHOENCX
# GETVISIT + BEHOVM2 VUNITS):
#   { measurement_ien:, patient_dfn:, type:, value:, units:, date:,
#     visit_ien:, service_category:, capture_mode:, entered_in_error: }
# Condition rows use the verified ORQQPL LIST shape (ien/description/
# status/icd_code/onset_date/last_modified). The patient-phone scenario
# seeds the actual DDR GETS ENTRY DATA reply so RpmsRpc::Patient.contact
# parsing is exercised, not bypassed.

# -- Helpers ------------------------------------------------------------------

def vardana_get(path, params = {})
  (@fhir_headers || {}).each { |k, v| header k, v }
  query = params.any? ? "?#{URI.encode_www_form(params)}" : ""
  get "#{path}#{query}"
end

def vardana_bundle
  JSON.parse(last_response.body)
end

def vardana_entries
  vardana_bundle["entry"] || []
end

def vardana_resources
  vardana_entries.map { |e| e["resource"] }
end

def measurement_row(ien:, type:, value:, units:, date:, service_category: nil,
                    entered_in_error: false, visit_ien: nil, provider_name: nil, dfn: 1)
  {
    measurement_ien: ien.to_i, patient_dfn: dfn.to_i, type: type, value: value,
    units: units, date: date, visit_ien: visit_ien,
    service_category: service_category,
    capture_mode: RpmsRpc::Measurement.capture_mode_for(service_category),
    entered_in_error: entered_in_error, provider_name: provider_name
  }
end

# -- Givens: observation fixtures --------------------------------------------

Given("patient {string} has a clinic-measured blood pressure and a telecom-captured weight") do |dfn|
  # SERVICE CATEGORY "A" (ambulatory, in-person) vs "T" (telecommunications) —
  # VISIT file 9000010 field .07, carried onto the measurement's parent visit.
  @bp_obs_id = "5001"
  @wt_obs_id = "5002"
  stub_gateway(Lakeraven::EHR::ObservationGateway, :for_patient, [
    measurement_row(ien: @bp_obs_id, type: "BP", value: "138/88", units: "mmHg",
                    date: Time.utc(2025, 1, 15, 8, 30), service_category: "A",
                    visit_ien: 9001, provider_name: "PROVIDER,TEST", dfn: dfn),
    measurement_row(ien: @wt_obs_id, type: "WT", value: "152", units: "lb",
                    date: Time.utc(2025, 1, 16, 9, 0), service_category: "T",
                    visit_ien: 9002, dfn: dfn)
  ])
end

Given("the telecom-captured weight measurement is readable by IEN") do
  @wt_obs_id = "5002"
  stub_gateway(Lakeraven::EHR::ObservationGateway, :find,
    measurement_row(ien: @wt_obs_id, type: "WT", value: "152", units: "lb",
                    date: Time.utc(2025, 1, 16, 9, 0), service_category: "T",
                    visit_ien: 9002, dfn: 1))
end

Given("patient {string} has a vital with no recorded service category") do |dfn|
  stub_gateway(Lakeraven::EHR::ObservationGateway, :for_patient, [
    measurement_row(ien: 5003, type: "P", value: "72", units: "/min",
                    date: Time.utc(2025, 1, 15, 8, 30), dfn: dfn)
  ])
end

Given("patient {string} has weight observations recorded on {string}, {string} and {string}") do |dfn, d1, d2, d3|
  rows = [ d1, d2, d3 ].each_with_index.map do |d, i|
    date = Date.parse(d)
    measurement_row(ien: 6100 + i, type: "WT", value: "150", units: "lb",
                    date: Time.utc(date.year, date.month, date.day, 8, 0), dfn: dfn)
  end
  stub_gateway(Lakeraven::EHR::ObservationGateway, :for_patient, rows)
  @stubbed_observation_rows = rows
end

Given("patient {string} has {int} weight observations on consecutive days") do |dfn, count|
  rows = (1..count).map do |day|
    measurement_row(ien: 6200 + day, type: "WT", value: (140 + day).to_s, units: "lb",
                    date: Time.utc(2025, 3, day, 8, 0), dfn: dfn)
  end
  stub_gateway(Lakeraven::EHR::ObservationGateway, :for_patient, rows)
end

Given("patient {string} has a weight measurement with no source unit") do |dfn|
  # BEHOVM2 VUNITS unreachable / type unknown → units nil. §5.1: the value
  # is dropped, never emitted with a guessed unit.
  stub_gateway(Lakeraven::EHR::ObservationGateway, :for_patient, [
    measurement_row(ien: 6301, type: "WT", value: "150", units: nil,
                    date: Time.utc(2025, 3, 1, 8, 0), dfn: dfn)
  ])
end

Given("patient {string} has two weight measurements taken in the same minute") do |dfn|
  # Identity is the V MEASUREMENT IEN, so same type + same minute must
  # still yield two distinct ids.
  stub_gateway(Lakeraven::EHR::ObservationGateway, :for_patient, [
    measurement_row(ien: 6401, type: "WT", value: "150", units: "lb",
                    date: Time.utc(2025, 3, 1, 8, 0, 10), dfn: dfn),
    measurement_row(ien: 6402, type: "WT", value: "151", units: "lb",
                    date: Time.utc(2025, 3, 1, 8, 0, 40), dfn: dfn)
  ])
end

Given("patient {string} has a blood pressure entered in error and a corrected replacement") do |dfn|
  # ENTERED IN ERROR is V MEASUREMENT #9000010.01 field 2 (stored by
  # EIE^BEHOVM2), read over the wire via DDR GETS ENTRY DATA.
  stub_gateway(Lakeraven::EHR::ObservationGateway, :for_patient, [
    measurement_row(ien: 6001, type: "BP", value: "310/210", units: "mmHg",
                    date: Time.utc(2025, 2, 1, 10, 0), entered_in_error: true, dfn: dfn),
    measurement_row(ien: 6002, type: "BP", value: "130/82", units: "mmHg",
                    date: Time.utc(2025, 2, 1, 10, 5), entered_in_error: false, dfn: dfn)
  ])
end

# -- Givens: condition / medication / encounter fixtures ----------------------

Given("patient {string} has an active problem and an inactive problem") do |dfn|
  # Verified ORQQPL LIST row shape (LIST^ORQQPL): ien/description/status/
  # icd_code/onset_date/last_modified — status is #9000011 field .12
  # internal, "A"/"I". No recorded-date or provider on this wire.
  stub_gateway(Lakeraven::EHR::ConditionGateway, :for_patient, [
    { ien: "101", description: "Essential hypertension", status: "A", icd_code: "I10",
      onset_date: Date.new(2020, 3, 1), last_modified: Date.new(2020, 3, 2) },
    { ien: "102", description: "Sprain of ankle", status: "I", icd_code: "S93.401A",
      onset_date: Date.new(2018, 6, 1), last_modified: Date.new(2018, 6, 15) }
  ])
end

Given("patient {string} has an active medication and a discontinued medication") do |dfn|
  # ORQQPS LIST row shape: ien/drug_name/sig/status.
  stub_gateway(Lakeraven::EHR::MedicationRequestGateway, :for_patient, [
    { ien: "201", drug_name: "LISINOPRIL 10MG TAB", sig: "TAKE ONE TABLET BY MOUTH DAILY", status: "ACTIVE" },
    { ien: "202", drug_name: "IBUPROFEN 400MG TAB", sig: "TAKE ONE TABLET THREE TIMES DAILY", status: "DISCONTINUED" }
  ])
end

Given("patient {string} has encounters on {string}, {string} and {string}") do |dfn, d1, d2, d3|
  # ORWPT APPTLST row shape: datetime/location_ien/location/status.
  rows = [ d1, d2, d3 ].map do |d|
    date = Date.parse(d)
    { datetime: Time.utc(date.year, date.month, date.day, 9, 0),
      location_ien: 1, location: "Primary Care Clinic", status: "checked out" }
  end
  stub_gateway(Lakeraven::EHR::EncounterGateway, :for_patient, rows)
end

# -- Givens: patient fixture --------------------------------------------------

Given("patient {string} has a residence phone number {string} on file") do |dfn, phone|
  # PATIENT file (#2) field .131 PHONE NUMBER [RESIDENCE]. Seeds the real
  # DDR GETS ENTRY DATA reply RpmsRpc::Patient.contact issues (fields
  # .131/.132/.134/.133) so the wire parse itself is exercised.
  key = RpmsRpc::DdrFileman.gets_entry_param(
    file: "2", iens: "#{dfn.to_i},", fields: ".131;.132;.134;.133", flags: "IE"
  ).to_s
  RpmsRpc.client.seed(:ddr_gets_entry_data, key, <<~REPLY.chomp)
    [Data]
    2^#{dfn.to_i}^.131^#{phone}^#{phone}
    2^#{dfn.to_i}^.132^^
    2^#{dfn.to_i}^.134^^
    2^#{dfn.to_i}^.133^^
  REPLY
end

# -- Whens --------------------------------------------------------------------

When("I request the Provenance for the weight by target only") do
  # No patient parameter — the by-IEN read supplies the patient itself.
  vardana_get("/lakeraven-ehr/Provenance", target: "Observation/#{@wt_obs_id}")
end

When("I request the Provenance resource by its id") do
  vardana_get("/lakeraven-ehr/Provenance/prov-#{@wt_obs_id}")
end

When("I read the observation ids for patient {string}") do |dfn|
  vardana_get("/lakeraven-ehr/Observation", patient: dfn)
  assert_equal 200, last_response.status
  @first_read_ids = vardana_resources.map { |r| r["id"] }
  assert @first_read_ids.any?, "Expected at least one observation on first read"
end

When("a new weight observation is recorded for patient {string} on {string}") do |dfn, date_str|
  date = Date.parse(date_str)
  rows = @stubbed_observation_rows + [
    measurement_row(ien: 6199, type: "WT", value: "149", units: "lb",
                    date: Time.utc(date.year, date.month, date.day, 8, 0), dfn: dfn)
  ]
  stub_gateway(Lakeraven::EHR::ObservationGateway, :for_patient, rows)
end

When("I read the observation ids for patient {string} again") do |dfn|
  vardana_get("/lakeraven-ehr/Observation", patient: dfn)
  assert_equal 200, last_response.status
  @second_read_ids = vardana_resources.map { |r| r["id"] }
end

When("I page through {string} for patient {string} with _count {string}") do |path, dfn, count|
  @pages = []
  vardana_get(path, patient: dfn, _count: count)
  assert_equal 200, last_response.status
  @pages << vardana_bundle
  while (next_link = (@pages.last["link"] || []).find { |l| l["relation"] == "next" })
    (@fhir_headers || {}).each { |k, v| header k, v }
    get next_link["url"]
    assert_equal 200, last_response.status
    @pages << vardana_bundle
    assert @pages.length <= 10, "Runaway pagination: more than 10 pages"
  end
end

# -- Thens: provenance --------------------------------------------------------

def provenance_targeting(obs_id)
  vardana_resources.find do |r|
    r["resourceType"] == "Provenance" &&
      Array(r["target"]).any? { |t| t["reference"] == "Observation/#{obs_id}" }
  end
end

# R4 Provenance.agent.type is 0..1 CodeableConcept — a single Hash, never
# an array. This helper is deliberately strict: an array-shaped type (the
# old, invalid serialization) fails here.
def agent_type_codes(provenance)
  Array(provenance["agent"]).flat_map do |a|
    type = a["type"]
    next [] if type.nil?

    assert type.is_a?(Hash),
      "Provenance.agent.type must be a single CodeableConcept (0..1), got #{type.class}"
    Array(type["coding"]).map { |c| c["code"] }
  end
end

Then("the bundle should contain a Provenance targeting the blood pressure with agent type {string}") do |type_code|
  prov = provenance_targeting(@bp_obs_id)
  refute_nil prov, "Expected a Provenance targeting Observation/#{@bp_obs_id}"
  assert_includes agent_type_codes(prov), type_code
end

Then("the bundle should contain a Provenance targeting the weight with no agent type") do
  prov = provenance_targeting(@wt_obs_id)
  refute_nil prov, "Expected a Provenance targeting Observation/#{@wt_obs_id}"
  assert_empty agent_type_codes(prov),
    "A non-office measurement must not assert an agent participant type"
end

Then("the weight Provenance should carry source modality {string} without asserting an informant") do |category|
  prov = provenance_targeting(@wt_obs_id)
  refute_nil prov
  activity_codes = Array(prov.dig("activity", "coding")).map { |c| c["code"] }
  assert_includes activity_codes, category,
    "Provenance.activity should carry the raw service category"
  Array(prov["agent"]).each do |agent|
    reference = agent.dig("who", "reference").to_s
    refute reference.start_with?("Patient/"),
      "The wire records capture modality, not an informant — who=Patient must not be asserted"
    assert_match(/not office-measured/i, agent.dig("who", "display").to_s)
  end
end

Then("every Provenance should be valid FHIR R4") do
  provs = vardana_resources.select { |r| r["resourceType"] == "Provenance" }
  assert provs.any?, "Expected at least one Provenance in the bundle"
  provs.each do |p|
    assert Array(p["target"]).any?, "Provenance.target is 1..*"
    assert Array(p["agent"]).any?, "Provenance.agent is 1..*"
    refute_nil p["recorded"], "Provenance.recorded is 1..1"
    refute_nil Time.iso8601(p["recorded"]), "Provenance.recorded must be an instant"
    Array(p["agent"]).each do |agent|
      refute_nil agent["who"], "Provenance.agent.who is 1..1"
      type = agent["type"]
      assert(type.nil? || type.is_a?(Hash),
        "Provenance.agent.type is 0..1 CodeableConcept — not an array")
    end
  end
end

Then("the Provenance target should reference the weight observation") do
  prov = JSON.parse(last_response.body)
  references = Array(prov["target"]).map { |t| t["reference"] }
  assert_includes references, "Observation/#{@wt_obs_id}"
end

# -- Thens: bundles and search ------------------------------------------------

Then("the bundle should contain exactly {int} entry/entries") do |count|
  assert_equal count, vardana_entries.length,
    "Expected #{count} entries, got #{vardana_entries.length}: #{vardana_resources.map { |r| r['id'] }.inspect}"
end

Then("the bundle total should be {int}") do |total|
  assert_equal total, vardana_bundle["total"]
end

Then("every Condition in the bundle should have clinical status {string}") do |status|
  conditions = vardana_resources.select { |r| r["resourceType"] == "Condition" }
  assert conditions.any?
  conditions.each do |c|
    codes = Array(c.dig("clinicalStatus", "coding")).map { |x| x["code"] }
    assert_includes codes, status
  end
end

Then("the active Condition should be the hypertension problem") do
  condition = vardana_resources.find { |r| r["resourceType"] == "Condition" }
  assert_equal "101", condition["id"]
  assert_equal "Essential hypertension", condition.dig("code", "text"),
    "The real inactive row must not have shadowed the active one"
end

Then("every MedicationRequest in the bundle should have status {string}") do |status|
  meds = vardana_resources.select { |r| r["resourceType"] == "MedicationRequest" }
  assert meds.any?
  meds.each { |m| assert_equal status, m["status"] }
end

Then("every Observation in the bundle should have code {string}") do |code|
  observations = vardana_resources.select { |r| r["resourceType"] == "Observation" }
  assert observations.any?
  observations.each do |o|
    codes = Array(o.dig("code", "coding")).map { |c| c["code"] }
    assert_includes codes, code
  end
end

Then("every Observation effectiveDateTime should be on or after {string}") do |date_str|
  floor = Time.parse("#{date_str}T00:00:00Z")
  vardana_resources.each do |o|
    effective = o["effectiveDateTime"]
    refute_nil effective, "Observation #{o['id']} missing effectiveDateTime"
    assert Time.parse(effective) >= floor,
      "Observation #{o['id']} effectiveDateTime #{effective} is before #{date_str}"
  end
end

Then("the bundle observations should be sorted newest first") do
  times = vardana_resources.map { |o| Time.parse(o["effectiveDateTime"]) }
  assert_equal times.sort.reverse, times, "Expected observations sorted newest first"
end

Then("every Encounter in the bundle should have a class and a period") do
  encounters = vardana_resources.select { |r| r["resourceType"] == "Encounter" }
  assert encounters.any?
  encounters.each do |e|
    refute_nil e.dig("class", "code"), "Encounter #{e['id']} missing class"
    refute_nil e.dig("period", "start"), "Encounter #{e['id']} missing period.start"
  end
end

Then("the bundle encounters should be sorted newest first") do
  times = vardana_resources.map { |e| Time.parse(e.dig("period", "start")) }
  assert_equal times.sort.reverse, times, "Expected encounters sorted newest first"
end

# -- Thens: pagination --------------------------------------------------------

Then("I should have followed at least {int} next links") do |count|
  assert @pages.length >= count + 1,
    "Expected at least #{count} next links (#{count + 1} pages), got #{@pages.length} pages"
end

Then("the pages should collectively contain exactly {int} distinct observation ids") do |count|
  ids = @pages.flat_map { |p| (p["entry"] || []).map { |e| e.dig("resource", "id") } }
  assert_equal ids.length, ids.uniq.length, "Pages repeated an observation id"
  assert_equal count, ids.uniq.length,
    "Expected #{count} distinct ids across pages, got #{ids.uniq.length}: #{ids.inspect}"
end

Then("each page should contain at most {int} entries") do |count|
  @pages.each do |p|
    assert (p["entry"] || []).length <= count,
      "A page exceeded _count=#{count}: #{(p['entry'] || []).length} entries"
  end
end

# -- Thens: data quality ------------------------------------------------------

Then("every quantitative Observation should have a LOINC-coded code") do
  observations = vardana_resources.select { |r| r["resourceType"] == "Observation" }
  assert observations.any?
  observations.each do |o|
    systems = Array(o.dig("code", "coding")).map { |c| c["system"] }
    assert_includes systems, "http://loinc.org", "Observation #{o['id']} is not LOINC-coded"
  end
end

Then("every quantitative Observation should have a value with unit and unit system") do
  observations = vardana_resources.select { |r| r["resourceType"] == "Observation" }
  quantitative = observations.reject { |o| o["component"] }
  assert quantitative.any?
  quantitative.each do |o|
    vq = o["valueQuantity"]
    refute_nil vq, "Observation #{o['id']} has no valueQuantity"
    assert vq["value"].is_a?(Numeric), "Observation #{o['id']} valueQuantity.value is not numeric"
    refute_nil vq["unit"], "Observation #{o['id']} has no unit"
    assert_equal "http://unitsofmeasure.org", vq["system"]
  end
end

Then("every Observation should have an effectiveDateTime") do
  vardana_resources.each do |o|
    refute_nil o["effectiveDateTime"], "Observation #{o['id']} missing effectiveDateTime"
  end
end

def bp_component(code)
  bp = vardana_resources.find { |r| r["resourceType"] == "Observation" && r["component"] }
  refute_nil bp, "Expected a blood-pressure Observation with components"
  Array(bp["component"]).find do |c|
    Array(c.dig("code", "coding")).any? { |x| x["code"] == code }
  end
end

Then("the blood pressure should have component {string} with value {float} and unit {string}") do |code, value, unit|
  component = bp_component(code)
  refute_nil component, "Expected blood-pressure component #{code}"
  assert_equal value, component.dig("valueQuantity", "value")
  assert_equal unit, component.dig("valueQuantity", "unit")
end

Then("both blood pressure components should use unit system {string}") do |system|
  %w[8480-6 8462-4].each do |code|
    component = bp_component(code)
    assert_equal system, component.dig("valueQuantity", "system")
  end
end

Then("every originally read observation id should still be present with the same id") do
  missing = @first_read_ids - @second_read_ids
  assert_empty missing, "Ids changed or vanished across the data change: #{missing.inspect}"
  assert @second_read_ids.length > @first_read_ids.length,
    "Expected the data change to add an observation"
end

Then("the observation ids in the bundle should all be distinct and non-blank") do
  ids = vardana_resources.map { |r| r["id"] }
  assert ids.all?(&:present?), "No observation may carry a blank id: #{ids.inspect}"
  assert_equal ids.uniq.length, ids.length, "Observation ids collided: #{ids.inspect}"
end

Then("exactly {int} Observation in the bundle should have status {string}") do |count, status|
  matching = vardana_resources.count { |r| r["resourceType"] == "Observation" && r["status"] == status }
  assert_equal count, matching,
    "Expected #{count} observation(s) with status #{status}, got #{matching}"
end

# -- Thens: patient telecom ---------------------------------------------------

Then("the patient telecom should include a phone with value {string}") do |phone|
  patient = JSON.parse(last_response.body)
  phones = Array(patient["telecom"]).select { |t| t["system"] == "phone" }
  assert phones.any?, "Expected Patient.telecom to include a phone entry"
  assert_includes phones.map { |t| t["value"] }, phone
end
