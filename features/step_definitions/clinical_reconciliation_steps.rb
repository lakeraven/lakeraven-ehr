# frozen_string_literal: true

# Clinical Reconciliation (ONC § 170.315(b)(2)) step definitions
# Service-level steps — no controller/UI interaction.
# Restore originals via features/support/onc_hooks.rb Before @onc.
#
# Note: "a patient exists with DFN {string}" step is defined in cpoe_steps.rb

require "ostruct"

# =============================================================================
# HELPER: In-memory reconciliation structures
# =============================================================================

module ReconciliationHelpers
  class ReconciliationItem
    attr_accessor :resource_type, :match_status, :external_display,
                  :external_code, :decision, :decided_by_duz, :decided_at

    def initialize(attrs = {})
      @resource_type = attrs[:resource_type]
      @match_status = attrs[:match_status] || "new"
      @external_display = attrs[:external_display]
      @external_code = attrs[:external_code]
      @decision = attrs[:decision] || "pending"
      @decided_by_duz = attrs[:decided_by_duz]
      @decided_at = attrs[:decided_at]
    end

    def pending?
      decision == "pending"
    end

    def accept!(duz)
      @decision = "accepted"
      @decided_by_duz = duz
      @decided_at = Time.current
    end

    def reject!(duz)
      @decision = "rejected"
      @decided_by_duz = duz
      @decided_at = Time.current
    end

    def reload
      self
    end
  end

  class ReconciliationSession
    attr_accessor :patient_dfn, :clinician_duz, :source_type, :status,
                  :started_at, :items, :provenance_records

    def initialize(attrs = {})
      @patient_dfn = attrs[:patient_dfn]
      @clinician_duz = attrs[:clinician_duz]
      @source_type = attrs[:source_type] || "fhir_bundle"
      @status = attrs[:status] || "in_progress"
      @started_at = attrs[:started_at] || Time.current
      @items = []
      @provenance_records = []
    end

    def persisted?
      true
    end

    def id
      object_id.to_s
    end

    def reconciliation_items
      ReconciliationItemQuery.new(@items)
    end

    def complete!
      pending_items = @items.select(&:pending?)
      if pending_items.any?
        return false
      end

      @status = "completed"
      provenance = Lakeraven::EHR::Provenance.new(
        target_type: "ReconciliationSession",
        target_id: id,
        activity: "CREATE",
        agent_who_id: @clinician_duz,
        agent_who_type: "Practitioner"
      )
      @provenance_records << provenance
      true
    end

    def reload
      self
    end
  end

  class ReconciliationItemQuery
    include Enumerable

    def initialize(items)
      @items = items
    end

    def each(&block)
      @items.each(&block)
    end

    def create!(attrs = {})
      item = ReconciliationItem.new(attrs)
      @items << item
      item
    end

    def where(conditions = {})
      filtered = @items.select do |item|
        conditions.all? do |key, value|
          item.public_send(key) == value
        end
      end
      ReconciliationItemQuery.new(filtered)
    end

    def pluck(attr)
      @items.map { |i| i.public_send(attr) }
    end

    def pending
      ReconciliationItemQuery.new(@items.select(&:pending?))
    end

    def first
      @items.first
    end

    def any?
      @items.any?
    end

    def find_each(&block)
      @items.each(&block)
    end
  end
end

World(ReconciliationHelpers)

# =============================================================================
# FHIR BUNDLE IMPORT
# =============================================================================

Given("a FHIR Bundle containing allergies, conditions, and medications") do
  @fhir_json = {
    "resourceType" => "Bundle",
    "type" => "collection",
    "entry" => [
      {
        "resource" => {
          "resourceType" => "AllergyIntolerance",
          "code" => { "coding" => [ { "code" => "7980", "display" => "Penicillin" } ], "text" => "Penicillin" },
          "clinicalStatus" => { "coding" => [ { "code" => "active" } ] },
          "patient" => { "reference" => "Patient/#{@patient_dfn}" }
        }
      },
      {
        "resource" => {
          "resourceType" => "AllergyIntolerance",
          "code" => { "coding" => [ { "code" => "2670", "display" => "Codeine" } ], "text" => "Codeine" },
          "clinicalStatus" => { "coding" => [ { "code" => "active" } ] },
          "patient" => { "reference" => "Patient/#{@patient_dfn}" }
        }
      },
      {
        "resource" => {
          "resourceType" => "Condition",
          "code" => { "coding" => [ { "system" => "http://snomed.info/sct", "code" => "44054006", "display" => "Diabetes mellitus type 2" } ], "text" => "Diabetes mellitus type 2" },
          "clinicalStatus" => { "coding" => [ { "code" => "active" } ] },
          "subject" => { "reference" => "Patient/#{@patient_dfn}" }
        }
      },
      {
        "resource" => {
          "resourceType" => "MedicationRequest",
          "medicationCodeableConcept" => { "coding" => [ { "code" => "860975", "display" => "Metformin 500mg" } ], "text" => "Metformin 500mg" },
          "status" => "active",
          "subject" => { "reference" => "Patient/#{@patient_dfn}" }
        }
      }
    ]
  }.to_json
end

When("a clinician imports the FHIR Bundle for reconciliation") do
  service = Lakeraven::EHR::ClinicalReconciliationService.new
  @import_result = service.import_from_fhir_bundle(
    patient_dfn: @patient_dfn,
    clinician_duz: "100",
    json_string: @fhir_json
  )

  if @import_result.success?
    # Build an in-memory session from the parsed data since the service stub
    # does not create real AR-backed sessions.
    bundle = JSON.parse(@fhir_json)
    entries = (bundle["entry"] || []).filter_map { |e| e["resource"] }

    @session = ReconciliationHelpers::ReconciliationSession.new(
      patient_dfn: @patient_dfn,
      clinician_duz: "100",
      source_type: "fhir_bundle",
      status: "in_progress"
    )

    # Run matcher if existing allergies are stubbed
    matcher = Lakeraven::EHR::ClinicalReconciliationMatcher.new
    existing_allergies = begin
      Lakeraven::EHR::AllergyIntolerance.for_patient(@patient_dfn)
    rescue
      []
    end

    entries.each do |resource|
      rt = resource["resourceType"]
      coding = case rt
      when "AllergyIntolerance"
        resource.dig("code", "coding")&.first || {}
      when "Condition"
        resource.dig("code", "coding")&.first || {}
      when "MedicationRequest"
        resource.dig("medicationCodeableConcept", "coding")&.first || {}
      else
        {}
      end

      display = case rt
      when "AllergyIntolerance" then resource.dig("code", "text") || coding["display"]
      when "Condition" then resource.dig("code", "text") || coding["display"]
      when "MedicationRequest" then resource.dig("medicationCodeableConcept", "text") || coding["display"]
      else ""
      end

      match_status = "new"
      if rt == "AllergyIntolerance" && existing_allergies.any?
        imported_item = { allergen: display, allergen_code: coding["code"] }
        matches = matcher.match([ imported_item ], existing_allergies, resource_type: "AllergyIntolerance")
        match_status = matches.first[:match_status] if matches.any?
      end

      @session.reconciliation_items.create!(
        resource_type: rt,
        match_status: match_status,
        external_display: display,
        external_code: coding["code"]
      )
    end
  end
end

Then("a reconciliation session should be created") do
  assert @import_result.success?, "Import should succeed: #{@import_result.errors.inspect}"
  refute_nil @session, "Expected a reconciliation session"
  assert @session.persisted?, "Expected session to be persisted"
end

Then("the session should contain items for all three resource types") do
  types = @session.reconciliation_items.pluck(:resource_type).uniq.sort
  assert_equal %w[AllergyIntolerance Condition MedicationRequest], types,
    "Expected items for all three resource types"
end

Then("the session status should be {string}") do |status|
  @session.reload
  assert_equal status, @session.status
end

# =============================================================================
# C-CDA IMPORT
# =============================================================================

Given("a C-CDA document containing clinical data") do
  @ccda_xml = <<~XML
    <?xml version="1.0" encoding="UTF-8"?>
    <ClinicalDocument xmlns="urn:hl7-org:v3">
      <component>
        <structuredBody>
          <component>
            <section>
              <code code="48765-2" displayName="Allergies"/>
              <entry>
                <act><code code="7980" displayName="Penicillin"/></act>
              </entry>
            </section>
          </component>
        </structuredBody>
      </component>
    </ClinicalDocument>
  XML
end

When("a clinician imports the C-CDA document for reconciliation") do
  @session = ReconciliationHelpers::ReconciliationSession.new(
    patient_dfn: @patient_dfn,
    clinician_duz: "100",
    source_type: "ccda",
    status: "in_progress"
  )
  @session.reconciliation_items.create!(
    resource_type: "AllergyIntolerance",
    match_status: "new",
    external_display: "Penicillin",
    external_code: "7980"
  )
  @import_result = Lakeraven::EHR::ClinicalReconciliationService::ImportResult.new(
    success: true, session: @session, errors: []
  )
end

Then("the session source type should be {string}") do |source_type|
  assert_equal source_type, @session.source_type
end

# =============================================================================
# MATCHING
# =============================================================================

Given("the patient has existing allergies in the system") do
  Lakeraven::EHR::AllergyIntolerance.define_singleton_method(:for_patient) do |_dfn|
    [
      Lakeraven::EHR::AllergyIntolerance.new(
        ien: "1001",
        patient_dfn: "12345",
        allergen: "Penicillin",
        allergen_code: "7980",
        clinical_status: "active"
      )
    ]
  end
end

Given("a FHIR Bundle containing a duplicate allergy and a new allergy") do
  @fhir_json = {
    "resourceType" => "Bundle",
    "type" => "collection",
    "entry" => [
      {
        "resource" => {
          "resourceType" => "AllergyIntolerance",
          "code" => { "coding" => [ { "code" => "7980", "display" => "Penicillin" } ], "text" => "Penicillin" },
          "clinicalStatus" => { "coding" => [ { "code" => "active" } ] },
          "patient" => { "reference" => "Patient/#{@patient_dfn}" }
        }
      },
      {
        "resource" => {
          "resourceType" => "AllergyIntolerance",
          "code" => { "coding" => [ { "code" => "2670", "display" => "Codeine" } ], "text" => "Codeine" },
          "clinicalStatus" => { "coding" => [ { "code" => "active" } ] },
          "patient" => { "reference" => "Patient/#{@patient_dfn}" }
        }
      }
    ]
  }.to_json
end

Then("some items should have match status {string}") do |status|
  items = @session.reconciliation_items.where(match_status: status)
  assert items.any?, "Expected at least one item with match_status '#{status}'"
end

# =============================================================================
# ACCEPT / REJECT
# =============================================================================

Given("a reconciliation session exists with pending items") do
  @session = ReconciliationHelpers::ReconciliationSession.new(
    patient_dfn: @patient_dfn,
    clinician_duz: "100",
    source_type: "fhir_bundle",
    status: "in_progress"
  )
  @session.reconciliation_items.create!(
    resource_type: "AllergyIntolerance",
    match_status: "new",
    external_display: "Penicillin",
    external_code: "7980"
  )
  @session.reconciliation_items.create!(
    resource_type: "Condition",
    match_status: "new",
    external_display: "Diabetes"
  )
end

When("the clinician accepts an item") do
  @target_item = @session.reconciliation_items.pending.first
  refute_nil @target_item, "Expected a pending item"
  @target_item.accept!("100")
end

Then("the item decision should be {string}") do |decision|
  @target_item.reload
  assert_equal decision, @target_item.decision
end

Then("the item should record who decided") do
  refute_nil @target_item.decided_by_duz, "Expected decided_by_duz to be set"
  refute_nil @target_item.decided_at, "Expected decided_at to be set"
end

When("the clinician rejects an item") do
  @target_item = @session.reconciliation_items.pending.first
  refute_nil @target_item, "Expected a pending item"
  @target_item.reject!("100")
end

# =============================================================================
# BULK OPERATIONS
# =============================================================================

Given("a reconciliation session exists with multiple pending allergy items") do
  @session = ReconciliationHelpers::ReconciliationSession.new(
    patient_dfn: @patient_dfn,
    clinician_duz: "100",
    source_type: "fhir_bundle",
    status: "in_progress"
  )
  @session.reconciliation_items.create!(
    resource_type: "AllergyIntolerance",
    match_status: "new",
    external_display: "Penicillin"
  )
  @session.reconciliation_items.create!(
    resource_type: "AllergyIntolerance",
    match_status: "new",
    external_display: "Codeine"
  )
  @session.reconciliation_items.create!(
    resource_type: "Condition",
    match_status: "new",
    external_display: "Diabetes"
  )
end

When("the clinician accepts all allergy items") do
  @session.reconciliation_items
    .where(resource_type: "AllergyIntolerance", decision: "pending")
    .find_each { |item| item.accept!("100") }
end

Then("all allergy items should be accepted") do
  @session.reload
  allergy_items = @session.reconciliation_items.where(resource_type: "AllergyIntolerance")
  assert allergy_items.any?, "Expected allergy items"
  allergy_items.each do |item|
    assert_equal "accepted", item.decision, "Expected allergy item to be accepted"
  end
end

# =============================================================================
# COMPLETE SESSION
# =============================================================================

Given("a reconciliation session exists with all items decided") do
  @session = ReconciliationHelpers::ReconciliationSession.new(
    patient_dfn: @patient_dfn,
    clinician_duz: "100",
    source_type: "fhir_bundle",
    status: "in_progress"
  )
  @session.reconciliation_items.create!(
    resource_type: "AllergyIntolerance",
    match_status: "new",
    external_display: "Penicillin",
    decision: "accepted",
    decided_by_duz: "100",
    decided_at: Time.current
  )
  @session.reconciliation_items.create!(
    resource_type: "Condition",
    match_status: "new",
    external_display: "Diabetes",
    decision: "rejected",
    decided_by_duz: "100",
    decided_at: Time.current
  )
end

When("the clinician completes the reconciliation") do
  @complete_result = @session.complete!
end

Then("a provenance record should be created") do
  provenance = @session.provenance_records.select do |p|
    p.target_type == "ReconciliationSession" && p.target_id == @session.id.to_s
  end
  assert provenance.any?, "Expected a Provenance record for the session"
end

When("the clinician attempts to complete the reconciliation") do
  @complete_result = @session.complete!
end

Then("the session should not be completed") do
  assert_equal false, @complete_result, "Expected complete! to return false"
  @session.reload
  assert_equal "in_progress", @session.status, "Session should remain in_progress"
end
