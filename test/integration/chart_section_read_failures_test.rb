# frozen_string_literal: true

require "test_helper"

# Chart sections whose RPMS read fails (#579, first slice).
#
# A refusal, an RPC the server does not offer, an M error and a programming
# error are not "no data". Each renders as an unavailable section with a
# cause-specific, PHI-free message (HTML) or an OperationOutcome entry (FHIR
# Bundle), never as the section's empty state.
class ChartSectionReadFailuresTest < ActionDispatch::IntegrationTest
  include SmartAuthTestHelper
  include IhsFeatureAvailabilityTestHelper

  PATIENT_DFN = "1"

  # Synthetic. Stands in for broker detail and PHI an exception message can carry.
  MARKER = "SECRET-BROKER-DETAIL"
  RAW_MESSAGE = "#{MARKER} DOE,JANE 000-00-0000".freeze

  ERRORS = {
    "RpcRefusedError" => { error: RpmsRpc::Client::RpcRefusedError, phrase: /not permitted/i, fhir_code: "forbidden" },
    "RpcNotAvailableError" => { error: RpmsRpc::Client::RpcNotAvailableError, phrase: /not offered/i, fhir_code: "not-supported" },
    "a plain RpcError" => { error: RpmsRpc::Client::RpcError, phrase: /could not be loaded/i, fhir_code: "exception" }
  }.freeze

  ALL_PHRASES = ERRORS.values.map { |cause| cause[:phrase] }.freeze

  HTML_SECTIONS = {
    "problems" => {
      id: "#chart-problems", empty: "No active problems recorded.",
      owner: -> { Lakeraven::EHR::Condition }, method: :for_patient
    },
    "medications" => {
      id: "#chart-medications", empty: "No active medications.",
      owner: -> { Lakeraven::EHR::MedicationRequest }, method: :for_patient
    },
    "vitals" => {
      id: "#chart-vitals", empty: "No vitals recorded.",
      owner: -> { Lakeraven::EHR::SupplementalClinicalResources }, method: :merged_observations_for_patient
    },
    "encounters" => {
      id: "#chart-encounters", empty: "No encounters or upcoming appointments.",
      owner: -> { Lakeraven::EHR::EncounterGateway }, method: :for_patient
    }
  }.freeze

  FHIR_READS = {
    "Condition" => { owner: -> { Lakeraven::EHR::Condition }, method: :for_patient },
    "MedicationRequest" => { owner: -> { Lakeraven::EHR::MedicationRequest }, method: :for_patient },
    "Observation" => { owner: -> { Lakeraven::EHR::SupplementalClinicalResources }, method: :merged_observations_for_patient },
    "Procedure" => { owner: -> { Lakeraven::EHR::Procedure }, method: :for_patient },
    "Encounter" => { owner: -> { Lakeraven::EHR::EncounterGateway }, method: :for_patient }
  }.freeze

  setup { setup_smart_auth(scopes: "system/*.read") }

  teardown do
    teardown_smart_auth
    teardown_restricted_backend
  end

  # -- HTML: four sections x three causes -------------------------------------

  HTML_SECTIONS.each do |name, section|
    ERRORS.each do |label, cause|
      test "chart #{name} section reports #{label} as unavailable, not as an empty section" do
        with_failing_read(section, cause[:error]) do
          get_chart_html
          assert_response :ok

          refute_includes response.body, section[:empty],
            "a failed #{name} read must not render the empty state"
          assert_select section[:id], text: cause[:phrase]
          (ALL_PHRASES - [ cause[:phrase] ]).each do |other|
            assert_select section[:id], { text: other, count: 0 },
              "#{name} failed with #{label}; its message must be specific to that cause"
          end
          assert_select "#{section[:id]} h2 span", { count: 0 }, "no count when the list did not load"
          assert_other_sections_rendered(except: name)
          refute_includes response.body, MARKER, "the exception message must not reach the page"
        end
      end
    end
  end

  test "chart problems section reports a NoMethodError as could not be loaded, not as an empty section" do
    with_failing_read(HTML_SECTIONS.fetch("problems"), NoMethodError) do
      get_chart_html
      assert_response :ok
      refute_includes response.body, "No active problems recorded."
      assert_select "#chart-problems", text: /could not be loaded/i
      assert_select "#chart-problems h2 span", { count: 0 }, "no count when the list did not load"
      assert_other_sections_rendered(except: "problems")
      refute_includes response.body, MARKER
    end
  end

  # -- Regression: a real [] is still the empty state --------------------------

  HTML_SECTIONS.each do |name, section|
    test "chart #{name} section still shows its empty state when the read returns no rows" do
      with_class_method(section[:owner].call, section[:method], ->(*) { [] }) do
        get_chart_html
        assert_response :ok
        assert_select section[:id], text: /#{Regexp.escape(section[:empty])}/
        ALL_PHRASES.each do |phrase|
          assert_select section[:id], { text: phrase, count: 0 }
        end
      end
    end
  end

  test "chart renders all four sections with a count and no failure message when every read succeeds" do
    get_chart_html
    assert_response :ok
    assert_other_sections_rendered(except: nil)
  end

  # -- FHIR Bundle: five resource types x three causes --------------------------

  FHIR_READS.each do |resource_type, read|
    ERRORS.each do |label, cause|
      test "chart FHIR bundle carries a #{cause[:fhir_code]} outcome when the #{resource_type} read raises #{label}" do
        with_failing_read(read, cause[:error]) do
          body = get_chart_bundle
          issue = outcome_issue_for(body, resource_type)
          assert issue, "expected an outcome entry naming #{resource_type}; outcomes: #{outcome_issues(body).inspect}"
          assert_equal cause[:fhir_code], issue["code"]
          assert_equal "error", issue["severity"]
          refute_includes issue["diagnostics"], MARKER
          refute_includes response.body, MARKER, "the exception message must not reach the bundle"
          assert_includes resource_types(body), "Patient", "the Patient resource stays in the bundle"
        end
      end
    end
  end

  test "chart FHIR bundle has no failure outcome when every read succeeds" do
    body = get_chart_bundle
    FHIR_READS.each_key do |resource_type|
      assert_nil outcome_issue_for(body, resource_type), "unexpected outcome naming #{resource_type}"
    end
    assert_includes resource_types(body), "Patient"
  end

  # -- Immunizations: a refusal is not the generic failure ---------------------

  test "chart Immunizations card reports RpcRefusedError as not permitted" do
    with_restricted_backend(capabilities: [ :ihs_immunization ]) do
      with_failing_read(immunization_read, RpmsRpc::Client::RpcRefusedError) do
        get_chart_html
        assert_response :ok
        assert_select "#chart-immunizations", text: /not permitted/i
        assert_select "#chart-immunizations", { text: /could not be loaded/i, count: 0 }
        assert_select "#chart-immunizations", { text: /not offered/i, count: 0 }
        refute_includes response.body, "No immunizations on file."
        assert_select "#chart-immunizations h2 span", { count: 0 }, "no count when the list did not load"
        refute_includes response.body, MARKER
      end
    end
  end

  test "chart FHIR bundle carries a forbidden outcome when the immunization read raises RpcRefusedError" do
    with_restricted_backend(capabilities: [ :ihs_immunization ]) do
      with_failing_read(immunization_read, RpmsRpc::Client::RpcRefusedError) do
        body = get_chart_bundle
        issue = outcome_issue_for(body, "Immunization")
        assert issue, "expected an outcome entry naming Immunization; outcomes: #{outcome_issues(body).inspect}"
        assert_equal "forbidden", issue["code"]
        refute_includes issue["diagnostics"], MARKER
        refute_includes response.body, MARKER
        assert_includes resource_types(body), "Patient"
      end
    end
  end

  # ===========================================================================
  # Round 2 (#579): gaps found in review.
  # ===========================================================================

  # -- 1. Allergies: a failed read is an outcome in the bundle ------------------

  ERRORS.each do |label, cause|
    test "chart FHIR bundle carries a #{cause[:fhir_code]} outcome when the allergy read raises #{label}" do
      with_failing_read(allergy_read, cause[:error]) do
        body = get_chart_bundle
        issue = outcome_issue_for(body, "AllergyIntolerance")
        assert issue, "expected an outcome entry naming AllergyIntolerance; outcomes: #{outcome_issues(body).inspect}"
        assert_equal cause[:fhir_code], issue["code"]
        assert_equal "error", issue["severity"]
        refute_includes issue["diagnostics"], MARKER
        refute_includes response.body, MARKER, "the exception message must not reach the bundle"
        refute_includes resource_types(body), "AllergyIntolerance", "a failed allergy read has no match entries"
        assert_includes resource_types(body), "Patient", "the Patient resource stays in the bundle"
      end
    end

    test "chart allergies section never reports none recorded when the allergy read raises #{label}" do
      with_failing_read(allergy_read, cause[:error]) do
        get_chart_html
        assert_response :ok
        assert_select "#chart-allergies", { count: 1 }
        assert_select "#chart-allergies", { text: /no known allergies/i, count: 0 }
        assert_select "#chart-allergies", { text: /none recorded/i, count: 0 }
        assert_select "#chart-allergies", { text: /no allergies/i, count: 0 }
        assert_select "#chart-allergies-table", { count: 0 }, "no allergy rows when the list did not load"
        refute_includes response.body, MARKER, "the exception message must not reach the page"
      end
    end
  end

  # -- 2. A section the token cannot read is not "none recorded" ---------------

  SCOPE_SECTIONS = HTML_SECTIONS.transform_values { |section| section.slice(:id, :empty) }.merge(
    "screenings" => { id: "#chart-screenings", empty: "No screenings recorded." }
  ).freeze

  SCOPE_SECTIONS.each do |name, section|
    test "chart #{name} section says not included, not none recorded, when the token cannot read it" do
      teardown_smart_auth
      setup_smart_auth(scopes: "system/Patient.read")

      get_chart_html
      assert_response :ok

      # The section may be omitted altogether; if it is on the page it must
      # not claim an empty list or a count.
      if css_select(section[:id]).any?
        assert_select section[:id], { text: /#{Regexp.escape(section[:empty])}/, count: 0 },
          "#{name} was not read for this token; the empty state is a clinical claim it cannot make"
        assert_select "#{section[:id]} h2 span", { count: 0 }, "no count for a section that was not read"
        assert_select section[:id], text: /not included/i
        ALL_PHRASES.each do |phrase|
          assert_select section[:id], { text: phrase, count: 0 }, "an unread section is not a failed read"
        end
      end
    end
  end

  # -- 3. Screenings read failure ----------------------------------------------

  test "chart screenings section reports a failed read as could not be loaded, not as an empty section" do
    with_failing_read(screening_read, ActiveRecord::StatementInvalid) do
      get_chart_html
      assert_response :ok
      assert_select "#chart-screenings", { text: /No screenings recorded\./, count: 0 },
        "a failed screenings read must not render the empty state"
      assert_select "#chart-screenings", text: /could not be loaded/i
      assert_select "#chart-screenings h2 span", { count: 0 }, "no count when the list did not load"
      assert_other_sections_rendered(except: "screenings")
      refute_includes response.body, MARKER, "the exception message must not reach the page"
    end
  end

  test "chart FHIR bundle carries an exception outcome naming QuestionnaireResponse when the screenings read raises" do
    with_failing_read(screening_read, ActiveRecord::StatementInvalid) do
      body = get_chart_bundle
      issue = outcome_issue_for(body, "QuestionnaireResponse")
      assert issue, "expected an outcome entry naming QuestionnaireResponse; outcomes: #{outcome_issues(body).inspect}"
      assert_equal "exception", issue["code"]
      assert_equal "error", issue["severity"]
      refute_includes issue["diagnostics"], MARKER
      refute_includes response.body, MARKER, "the exception message must not reach the bundle"
      assert_includes resource_types(body), "Patient", "the Patient resource stays in the bundle"
    end
  end

  # -- 4. Logs carry the exception class, never its message --------------------

  test "chart logs the class of a refused Condition read and never its message" do
    log = capture_rails_log do
      with_failing_read(FHIR_READS.fetch("Condition"), RpmsRpc::Client::RpcRefusedError) do
        get_chart_html
        assert_response :ok
      end
    end

    assert_includes log_text(log), "RpcRefusedError"
    refute_includes log_text(log), MARKER, "the exception message can carry PHI and must not be logged"
  end

  test "chart logs the class of a failed screenings read and never its message" do
    log = capture_rails_log do
      with_failing_read(screening_read, ActiveRecord::StatementInvalid) do
        get_chart_html
        assert_response :ok
      end
    end

    assert_includes log_text(log), "ActiveRecord::StatementInvalid"
    refute_includes log_text(log), MARKER, "the exception message can carry PHI and must not be logged"
  end

  # -- 5. A generic failure is an ERROR with a location; a refusal is a WARN ----

  test "chart logs a generic Condition read failure at ERROR with a source location and no message" do
    log = capture_rails_log do
      with_failing_read(FHIR_READS.fetch("Condition"), NoMethodError) do
        get_chart_html
        assert_response :ok
      end
    end

    errors = log.select { |entry| entry[:severity] == "ERROR" && entry[:message].include?("NoMethodError") }
    assert errors.any?,
      "expected an ERROR line naming NoMethodError; got #{entries_naming(log, 'NoMethodError').inspect}"
    assert errors.any? { |entry| entry[:message].match?(/\.rb:\d+/) },
      "the ERROR line must say where the error was raised (file:line); got #{errors.inspect}"
    refute_includes log_text(log), MARKER, "the exception message can carry PHI and must not be logged"
  end

  test "chart logs a refused Condition read at WARN, not ERROR" do
    log = capture_rails_log do
      with_failing_read(FHIR_READS.fetch("Condition"), RpmsRpc::Client::RpcRefusedError) do
        get_chart_html
        assert_response :ok
      end
    end

    naming = entries_naming(log, "RpcRefusedError")
    assert naming.any? { |entry| entry[:severity] == "WARN" }, "expected a WARN line naming RpcRefusedError; got #{naming.inspect}"
    assert naming.none? { |entry| entry[:severity] == "ERROR" }, "a refusal is not an error; got #{naming.inspect}"
    refute_includes log_text(log), MARKER
  end

  # -- 6. Immunizations: an RPC the server does not offer -----------------------

  test "chart Immunizations card reports RpcNotAvailableError as not offered" do
    with_restricted_backend(capabilities: [ :ihs_immunization ]) do
      with_failing_read(immunization_read, RpmsRpc::Client::RpcNotAvailableError) do
        get_chart_html
        assert_response :ok
        assert_select "#chart-immunizations", text: /not offered/i
        assert_select "#chart-immunizations", { text: /could not be loaded/i, count: 0 }
        assert_select "#chart-immunizations", { text: /not permitted/i, count: 0 }
        assert_select "#chart-immunizations", { text: /No immunizations on file\./, count: 0 }
        assert_select "#chart-immunizations h2 span", { count: 0 }, "no count when the list did not load"
        refute_includes response.body, MARKER
      end
    end
  end

  test "chart FHIR bundle carries a not-supported outcome when the immunization read raises RpcNotAvailableError" do
    with_restricted_backend(capabilities: [ :ihs_immunization ]) do
      with_failing_read(immunization_read, RpmsRpc::Client::RpcNotAvailableError) do
        body = get_chart_bundle
        issue = outcome_issue_for(body, "Immunization")
        assert issue, "expected an outcome entry naming Immunization; outcomes: #{outcome_issues(body).inspect}"
        assert_equal "not-supported", issue["code"]
        assert_equal "error", issue["severity"]
        refute_includes issue["diagnostics"], MARKER
        refute_includes response.body, MARKER
        assert_includes resource_types(body), "Patient"
      end
    end
  end

  # -- 7. Two sections failing at once -----------------------------------------

  test "chart reports a refused problems read and a not offered medications read each in its own section" do
    with_two_failing_reads do
      get_chart_html
      assert_response :ok

      assert_select "#chart-problems", text: /not permitted/i
      assert_select "#chart-problems", { text: /not offered/i, count: 0 }
      assert_select "#chart-problems h2 span", { count: 0 }
      assert_select "#chart-medications", text: /not offered/i
      assert_select "#chart-medications", { text: /not permitted/i, count: 0 }
      assert_select "#chart-medications h2 span", { count: 0 }
      refute_includes response.body, "No active problems recorded."
      refute_includes response.body, "No active medications."
      %w[vitals encounters].each do |name|
        section = HTML_SECTIONS.fetch(name)
        assert_select "#{section[:id]} h2 span", { count: 1 }, "the #{name} section still shows its count"
        ALL_PHRASES.each { |phrase| assert_select section[:id], { text: phrase, count: 0 } }
      end
      refute_includes response.body, MARKER
    end
  end

  test "chart FHIR bundle carries one outcome per type when two reads fail at once" do
    with_two_failing_reads do
      body = get_chart_bundle
      condition = outcome_issues(body).select { |issue| issue["diagnostics"].to_s.match?(/\bConditions?\b/) }
      medication = outcome_issues(body).select { |issue| issue["diagnostics"].to_s.match?(/\bMedicationRequests?\b/) }

      assert_equal [ "forbidden" ], condition.map { |issue| issue["code"] }, "one forbidden outcome naming Condition"
      assert_equal [ "not-supported" ], medication.map { |issue| issue["code"] }, "one not-supported outcome naming MedicationRequest"
      refute_includes resource_types(body), "Condition"
      refute_includes resource_types(body), "MedicationRequest"
      assert_includes resource_types(body), "Patient"
      refute_includes response.body, MARKER
    end
  end

  private

  # Records every Rails.logger call as { severity:, message: }, whatever the
  # formatter would have printed.
  class RecordingLogger < ActiveSupport::Logger
    attr_reader :entries

    def initialize
      super(StringIO.new)
      self.level = ::Logger::DEBUG
      @entries = []
    end

    def add(severity, message = nil, progname = nil)
      text = message || (block_given? ? yield : progname)
      @entries << { severity: ::Logger::SEV_LABEL[severity || ::Logger::UNKNOWN] || "ANY", message: text.to_s }
      true
    end
  end

  # Swap Rails.logger for the block; returns the recorded entries.
  def capture_rails_log
    original = Rails.logger
    recorder = RecordingLogger.new
    Rails.logger = ActiveSupport::TaggedLogging.new(recorder)
    yield
    recorder.entries
  ensure
    Rails.logger = original
  end

  def log_text(entries)
    entries.map { |entry| "#{entry[:severity]} #{entry[:message]}" }.join("\n")
  end

  def entries_naming(entries, name)
    entries.select { |entry| entry[:message].include?(name) }
  end

  def allergy_read
    { owner: -> { Lakeraven::EHR::SupplementalClinicalResources }, method: :merged_allergy_intolerances_for_patient }
  end

  def screening_read
    { owner: -> { Lakeraven::EHR::ScreeningResponse }, method: :for_patient }
  end

  def with_two_failing_reads(&block)
    with_failing_read(FHIR_READS.fetch("Condition"), RpmsRpc::Client::RpcRefusedError) do
      with_failing_read(FHIR_READS.fetch("MedicationRequest"), RpmsRpc::Client::RpcNotAvailableError, &block)
    end
  end

  def immunization_read
    { owner: -> { Lakeraven::EHR::ImmunizationGateway }, method: :for_patient }
  end

  def with_failing_read(read, error_class, &block)
    with_class_method(read[:owner].call, read[:method], ->(*) { raise error_class, RAW_MESSAGE }, &block)
  end

  # As with_gateway_method in ihs_feature_html_availability_test.rb: replace one
  # class method for the block, then put the original back.
  def with_class_method(owner, name, impl)
    original = owner.singleton_class.instance_method(name)
    owner.define_singleton_method(name, impl)
    yield
  ensure
    owner.define_singleton_method(name, original) if original
  end

  def get_chart_html
    get "/lakeraven-ehr/patients/#{PATIENT_DFN}", headers: @headers
  end

  def get_chart_bundle
    get "/lakeraven-ehr/patients/#{PATIENT_DFN}", headers: @headers.merge("Accept" => "application/fhir+json")
    assert_response :ok
    assert_equal "application/fhir+json", response.media_type
    JSON.parse(response.body)
  end

  def assert_other_sections_rendered(except:)
    HTML_SECTIONS.each do |name, section|
      next if name == except

      assert_select section[:id], { count: 1 }, "the #{name} section is still rendered"
      assert_select "#{section[:id]} h2 span", { count: 1 }, "the #{name} section still shows its count"
      ALL_PHRASES.each do |phrase|
        assert_select section[:id], { text: phrase, count: 0 }, "the #{name} section did not fail"
      end
    end
  end

  def outcome_issues(body)
    body.fetch("entry")
      .select { |entry| entry.dig("search", "mode") == "outcome" }
      .filter_map { |entry| entry.dig("resource", "issue", 0) if entry.dig("resource", "resourceType") == "OperationOutcome" }
  end

  # Whole-word match, so "Condition" is not found inside another type's name.
  def outcome_issue_for(body, resource_type)
    outcome_issues(body).find { |issue| issue["diagnostics"].to_s.match?(/\b#{resource_type}s?\b/) }
  end

  def resource_types(body)
    body.fetch("entry").filter_map { |entry| entry.dig("resource", "resourceType") }
  end
end
