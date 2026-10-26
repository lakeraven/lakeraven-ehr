# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class FhirReadEgressTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

      setup do
        setup_smart_auth(scopes: "system/*.read system/*.write")

        post "/lakeraven-ehr/exports", params: { export_type: "patient", patient_dfn: "1" }, headers: @headers
        export_body = JSON.parse(response.body)
        @export_id = export_body["id"]

        get "/lakeraven-ehr/exports/#{@export_id}", headers: @headers
        manifest = JSON.parse(response.body)
        @manifest_output = manifest["output"]

        patient_file = manifest["output"]&.find { |f| f["type"] == "Patient" }
        @export_file_url = patient_file&.dig("url")
        @export_file_path = @export_file_url ? URI.parse(@export_file_url).path : "/lakeraven-ehr/exports/#{@export_id}/files/patient.ndjson"

        @audit_csv_file = manifest["output"]&.find { |f| f["type"] == "audit_csv" }
        @audit_csv_file_url = @audit_csv_file&.dig("url")
        @audit_csv_file_path = @audit_csv_file_url ? URI.parse(@audit_csv_file_url).path : "/lakeraven-ehr/exports/#{@export_id}/files/audit_log.csv"

        @audit_event = AuditEvent.create!(
          event_type: "rest", action: "R", outcome: "0",
          entity_type: "Patient", entity_identifier: "1"
        )
      end

      teardown do
        ActionController::Base.allow_forgery_protection = @forgery_was unless @forgery_was.nil?
        teardown_smart_auth
      end

      # STUBBED_ACTIONS: actions that exist but render 404 or empty content.
      # When implemented with data, they must be wired to Part2EgressFilter and moved to WIRED_ACTIONS.
      STUBBED_ACTIONS = [
        "lakeraven/ehr/allergy_intolerances#show",
        "lakeraven/ehr/conditions#show",
        "lakeraven/ehr/medication_requests#show",
        "lakeraven/ehr/observations#show",
        "lakeraven/ehr/consents#show"
      ].freeze

      # Non-disclosing or out-of-scope controller actions that are explicitly allowed to bypass the seam.
      ALLOWED_WITHOUT_SEAM = [
        "lakeraven/ehr/demo_visits#show",     # Dev-gated demo UI, not API egress
        "lakeraven/ehr/demo_visits#vitals",   # Dev-gated demo UI
        "lakeraven/ehr/demo_visits#pov",      # Dev-gated demo UI
        "lakeraven/ehr/demo_visits#note",     # Dev-gated demo UI
        "lakeraven/ehr/demo_visits#close",    # Dev-gated demo UI
        "lakeraven/ehr/demo_visits#reset",    # Dev-gated demo UI
        "lakeraven/ehr/demo_visits#new",      # Dev-gated demo UI
        "lakeraven/ehr/demo_visits#summary",  # Dev-gated demo UI
        "lakeraven/ehr/screenings#create",    # Session-authenticated clinician UI (entry, not disclosure)
        "lakeraven/ehr/screenings#new",       # Session-authenticated clinician UI (entry, not disclosure)
        "lakeraven/ehr/sessions#new",         # Web UI login
        "lakeraven/ehr/sessions#create",      # Web UI login
        "lakeraven/ehr/sessions#destroy",     # Web UI logout
        "lakeraven/ehr/dashboards#show",      # Web UI dashboard; banner patient/allergy via filter_fhir_for_egress
        "lakeraven/ehr/test_sessions#create", # Test only
        "lakeraven/ehr/smart_configuration#show", # Discovery
        "lakeraven/ehr/smart_launch#show",    # Discovery
        "lakeraven/ehr/capability_statements#show", # Discovery
        "lakeraven/ehr/backend_services#token", # Auth
        "lakeraven/ehr/transitions_of_care#create", # Wired separately in #568
        "lakeraven/ehr/ccda_imports#create",  # Ingress
        "lakeraven/ehr/exports#create",       # Status/kickoff, no clinical data
        "lakeraven/ehr/exports#show",         # Status/kickoff
        "lakeraven/ehr/exports#destroy",      # Status/kickoff
        "lakeraven/ehr/patient_contexts#create", # Session context
        "lakeraven/ehr/active_patient_contexts#destroy", # Closes session context, no clinical data
        "lakeraven/ehr/practitioners#index",  # Directory data
        "lakeraven/ehr/practitioners#show",   # Directory data
        "lakeraven/ehr/organizations#show",   # Directory data
        "lakeraven/ehr/locations#show",       # Directory data
        "lakeraven/ehr/value_sets#index",     # Terminology
        "lakeraven/ehr/value_sets#show",      # Terminology
        "lakeraven/ehr/value_sets#expand",    # Terminology
        "lakeraven/ehr/measures#index",       # Measure definitions
        "lakeraven/ehr/measures#import"       # Measure definitions
      ].freeze

      WIRED_ACTIONS = [
        "lakeraven/ehr/patients#index",
        "lakeraven/ehr/patients#show",
        "lakeraven/ehr/patients#create",
        "lakeraven/ehr/charts#show",
        "lakeraven/ehr/screenings#index",
        "lakeraven/ehr/screenings#show",
        "lakeraven/ehr/allergy_intolerances#index",
        "lakeraven/ehr/conditions#index",
        "lakeraven/ehr/medication_requests#index",
        "lakeraven/ehr/observations#index",
        "lakeraven/ehr/encounters#index",
        "lakeraven/ehr/service_requests#index",
        "lakeraven/ehr/immunizations#index",
        "lakeraven/ehr/procedures#index",
        "lakeraven/ehr/coverage_eligibility_requests#create",
        "lakeraven/ehr/measure_reports#index",
        "lakeraven/ehr/consents#index",
        "lakeraven/ehr/audit_events#index",
        "lakeraven/ehr/audit_events#show",
        "lakeraven/ehr/export_files#show"
      ].freeze

      test "completeness: all disclosing FHIR read routes are tested for seam wiring" do
        routes = Lakeraven::EHR::Engine.routes.routes
        controller_actions = routes.map do |r|
          controller = r.defaults[:controller]
          action = r.defaults[:action]
          "#{controller}##{action}" if controller && action
        end.compact.uniq

        untested = controller_actions - ALLOWED_WITHOUT_SEAM - WIRED_ACTIONS - STUBBED_ACTIONS

        assert_empty untested, "Found routes that might disclose clinical data but are not explicitly tested for seam wiring or allowlisted."
      end

      test "completeness: all WIRED_ACTIONS are exercised by a WIRED_ENDPOINTS test" do
        tested_actions = WIRED_ENDPOINTS.map do |endpoint|
          path = endpoint[:path] || (endpoint[:dynamic_path] ? instance_exec(&endpoint[:dynamic_path]) : nil)
          route = Rails.application.routes.recognize_path(path, method: endpoint[:method])
          "#{route[:controller]}##{route[:action]}"
        end.compact.uniq

        untested = WIRED_ACTIONS - tested_actions
        assert_empty untested, "Found WIRED_ACTIONS that are not exercised in WIRED_ENDPOINTS"
      end

      test "export fails if patient is not found" do
        post "/lakeraven-ehr/exports", params: { export_type: "patient", patient_dfn: "99999" }, headers: @headers
        export_body = JSON.parse(response.body)

        get "/lakeraven-ehr/exports/#{export_body['id']}", headers: @headers
        # Wait, Bulk Export specifies 500 or just error status for GET /exports/:id if it failed.
        # Typically it returns 500 with OperationOutcome. Let's just check the response is an error.
        assert_response :error

        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
        assert_equal "Export failed", body.dig("issue", 0, "diagnostics")
      end

      test "export fails if a single resource type fetch raises an error" do
        # Method-swap one fetch to raise
        service_class = Lakeraven::EHR::EhiExportService
        original_fetch = service_class.instance_method(:fetch_conditions)

        begin
          service_class.define_method(:fetch_conditions) do |*args|
            raise "Sentinel error during fetch"
          end

          post "/lakeraven-ehr/exports", params: { export_type: "patient", patient_dfn: "1" }, headers: @headers
          export_body = JSON.parse(response.body)

          get "/lakeraven-ehr/exports/#{export_body['id']}", headers: @headers
          assert_response :error

          body = JSON.parse(response.body)
          assert_equal "Export failed", body.dig("issue", 0, "diagnostics")
        ensure
          service_class.define_method(:fetch_conditions, original_fetch)
        end
      end

      test "export honours _type parameter" do
        post "/lakeraven-ehr/exports", params: { export_type: "patient", patient_dfn: "1", _type: "Patient" }, headers: @headers
        export_body = JSON.parse(response.body)
        get "/lakeraven-ehr/exports/#{export_body['id']}", headers: @headers
        manifest = JSON.parse(response.body)

        types = manifest["output"].map { |f| f["type"] }
        assert_includes types, "Patient"
        refute_includes types, "AllergyIntolerance"
        refute_includes types, "Condition"
      end

      test "export supports legacy type parameter" do
        post "/lakeraven-ehr/exports", params: { export_type: "patient", patient_dfn: "1", type: "Patient" }, headers: @headers
        assert_response :accepted
      end

      test "export refuses _type parameter with unsupported resource types with 400 Bad Request" do
        post "/lakeraven-ehr/exports", params: { export_type: "patient", patient_dfn: "1", _type: "Immunization" }, headers: @headers
        assert_response :bad_request

        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
        assert_includes body.dig("issue", 0, "diagnostics"), "unsupported resource types: Immunization"
      end

      test "export refuses _since parameter with 400 Bad Request" do
        post "/lakeraven-ehr/exports", params: { export_type: "patient", patient_dfn: "1", _since: "2026-01-01T00:00:00Z" }, headers: @headers
        assert_response :bad_request

        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
        assert_equal "The _since parameter is not supported", body.dig("issue", 0, "diagnostics")
      end

      test "real export completes and yields a downloadable file for every item in manifest" do
        assert @manifest_output.present?, "Expected manifest to contain output files"

        @manifest_output.each do |file_info|
          file_url = file_info["url"]
          assert file_url, "Expected URL for file #{file_info['type']}"
          file_path = URI.parse(file_url).path

          get file_path, headers: @headers
          assert_response :success

          file_ext = File.extname(file_path)
          if file_ext == ".ndjson"
            assert_equal "application/fhir+ndjson", response.media_type
            response.body.each_line do |line|
              next if line.strip.empty?
              resource = JSON.parse(line)
              assert resource["resourceType"], "Expected parsed JSON to have a resourceType"
            end
            assert_includes response.body, "Anderson" if file_info["type"] == "Patient"
          elsif file_ext == ".csv"
            assert_equal "text/csv", response.media_type
            assert_kind_of String, response.body
            assert_includes response.body, "Event Type"
          elsif file_ext == ".json"
            assert_equal "application/json", response.media_type
            assert_kind_of String, response.body
            parsed = JSON.parse(response.body)
            assert_kind_of Hash, parsed
          end
        end
      end

      test "FHIR JSON endpoint fails closed if filter returns empty hash" do
        stub_egress_filter(->(payload) { {} }) do
          get "/lakeraven-ehr/Patient/1", headers: @headers
        end
        assert_response :service_unavailable
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
      end

      test "FHIR JSON endpoint fails closed if filter returns hash without resourceType" do
        stub_egress_filter(->(payload) { { "foo" => 1 } }) do
          get "/lakeraven-ehr/Patient/1", headers: @headers
        end
        assert_response :service_unavailable
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
      end

      test "FHIR JSON endpoint fails closed if filter returns hash with empty resourceType" do
        stub_egress_filter(->(payload) { { "resourceType" => "" } }) do
          get "/lakeraven-ehr/Patient/1", headers: @headers
        end
        assert_response :service_unavailable
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
      end

      test "Export file fails closed if filter returns invalid NDJSON string" do
        stub_egress_filter(->(payload) { "filter failed" }) do
          get @export_file_path, headers: @headers
        end
        assert_response :service_unavailable
        refute_includes response.body, "resourceType"
      end

      test "Export file allows empty string as valid empty NDJSON" do
        stub_egress_filter(->(payload) { "" }) do
          get @export_file_path, headers: @headers
        end
        assert_response :success
        assert_equal "", response.body
      end

      test "Export file fails closed if seam returns nil for non-NDJSON file" do
        stub_egress_filter(->(payload) { nil }) do
          get @audit_csv_file_path, headers: @headers
        end
        assert_response :service_unavailable
        assert_empty response.body, "Expected no file content when filter returns nil"
      end

      test "Export file fails closed if filter returns non-String for CSV type" do
        stub_egress_filter(->(payload) { { "invalid" => "csv" } }) do
          get @audit_csv_file_path, headers: @headers
        end
        assert_response :service_unavailable
        assert_empty response.body, "Expected no file content when filter returns a non-String for CSV"
      end

      test "Export CSV file fails closed if first line does not match audit headers" do
        stub_egress_filter(->(payload) { "arbitrary text,not,headers\nvalue,value" }) do
          get @audit_csv_file_path, headers: @headers
        end
        assert_response :service_unavailable
      end

      test "Export JSON file fails closed if filter returns scalar or null instead of an object" do
        config_path = @manifest_output.find { |f| f["type"] == "configuration" }&.dig("url")
        config_path = config_path ? URI.parse(config_path).path : "/lakeraven-ehr/exports/#{@export_id}/files/configuration.json"

        # Mock filter to return a scalar JSON string
        stub_egress_filter(->(payload) { "\"just a string\"" }) do
          get config_path, headers: @headers
        end
        assert_response :service_unavailable

        # Mock filter to return JSON null
        stub_egress_filter(->(payload) { "null" }) do
          get config_path, headers: @headers
        end
        assert_response :service_unavailable
      end

      test "HTML chart fails closed if filter returns empty hash" do
        stub_egress_filter(->(payload) { {} }) do
          get "/lakeraven-ehr/patients/1", headers: @headers
        end
        assert_response :service_unavailable
        refute_includes response.body, "120/80"
      end

      test "HTML chart fails closed if filter returns hash without resourceType" do
        stub_egress_filter(->(payload) { { "foo" => 1 } }) do
          get "/lakeraven-ehr/patients/1", headers: @headers
        end
        assert_response :service_unavailable
        refute_includes response.body, "120/80"
      end

            test "HTML chart retains RPMS text for appointments, missing vitals, and units" do
        begin
          RpmsRpc.client.seed_keyed_collection(:patient_appointments, "1", [
            { datetime: Date.new(2026, 2, 1), location_ien: 1, location: "Clinic", status: "no show" }
          ])
          RpmsRpc.client.seed_keyed_collection(:vitals, "1", [
            { measurement_ien: 4001, type: "PAIN", value: "4", units: "", recorded_date: DateTime.now },
            { measurement_ien: 4002, type: "T", value: "98.6", units: "Celsius", recorded_date: DateTime.now },
            { measurement_ien: 4003, type: "BP", value: "Refused", units: "", recorded_date: DateTime.now }
          ])

          get "/lakeraven-ehr/patients/1", headers: @headers
          assert_response :success

          assert_includes response.body, "No Show", "Expected appointment status to not be relabelled to cancelled"
          refute_match /cancelled/i, response.body, "Expected appointment status to not be relabelled to cancelled"

          assert_includes response.body, "PAIN", "Expected unmapped vital (PAIN) to be rendered"
          assert_includes response.body, "Refused", "Expected non-numeric vital value to be rendered"

          get "/lakeraven-ehr/patients/1.json", headers: @headers
          assert_response :success
          fhir_bundle = JSON.parse(response.body)
          temp_obs = fhir_bundle["entry"].find do |e|
            e.dig("resource", "resourceType") == "Observation" &&
              e.dig("resource", "code", "coding")&.any? { |c| c["code"] == "8310-5" }
          end
          fhir_unit = temp_obs.dig("resource", "valueQuantity", "unit")

          refused_obs = fhir_bundle["entry"].find do |e|
            e.dig("resource", "resourceType") == "Observation" &&
              e.dig("resource", "code", "coding")&.any? { |c| c["code"] == "85354-9" }
          end
          assert_equal "Refused", refused_obs.dig("resource", "valueString")

          get "/lakeraven-ehr/patients/1", headers: @headers
          assert_response :success
          html = Nokogiri::HTML(response.body)
          vital_div = html.css(".vital").find { |div| div.at_css(".lbl")&.text == "Body Temperature" }
          html_unit = vital_div.at_css(".val .u")&.text

          assert_equal fhir_unit.to_s, html_unit.to_s, "Expected HTML chart unit to match FHIR JSON unit"
        ensure
          RpmsRpc.client.seed_keyed_collection(:patient_appointments, "1", [])
          RpmsRpc.client.seed_keyed_collection(:vitals, "1", [
            { measurement_ien: 4004, type: "BP",  value: "120/80", units: "mm[Hg]", recorded_date: Time.new(2025, 1, 15, 9, 0, 0) },
            { measurement_ien: 4005, type: "P",   value: "72",     units: "/min",   recorded_date: Time.new(2025, 1, 15, 9, 0, 0) },
            { measurement_ien: 4006, type: "T",   value: "98.6",   units: "[degF]", recorded_date: Time.new(2025, 1, 15, 9, 0, 0) },
            { measurement_ien: 4007, type: "R",   value: "16",     units: "/min",   recorded_date: Time.new(2025, 1, 15, 9, 0, 0) },
            { measurement_ien: 4008, type: "POX", value: "98",     units: "%",      recorded_date: Time.new(2025, 1, 15, 9, 0, 0) },
            { measurement_ien: 4009, type: "WT",  value: "150",    units: "[lb_av]", recorded_date: Time.new(2025, 1, 15, 9, 0, 0) },
            { measurement_ien: 4010, type: "HT",  value: "65",     units: "[in_i]", recorded_date: Time.new(2025, 1, 15, 9, 0, 0) }
          ])
        end
      end

      test "failed export status does not leak raw exception text" do
        service_class = EhiExportService
        original_export = service_class.instance_method(:export)

        begin
          service_class.define_method(:export) do |*args, **kwargs|
            raise "SENTINEL-PHI-123: Database connection failed"
          end

          post "/lakeraven-ehr/exports", params: { export_type: "patient", patient_dfn: "1" }, headers: @headers
          export_body = JSON.parse(response.body)
          failed_export_id = export_body["id"]

          get "/lakeraven-ehr/exports/#{failed_export_id}", headers: @headers

          assert_response :error
          refute_includes response.body, "SENTINEL-PHI-123", "Expected failed export status not to leak raw exception text"
        ensure
          service_class.define_method(:export, original_export)
        end
      end

      # Table-driven tests for each wired endpoint that can be successfully invoked with seeded data.
      # Note: Many /:id show routes (like Consent/:id, AllergyIntolerance/:id) are omitted here because
      # we do not have seeded data for those specific resource IDs. We use the nearest real path
      # (the index search route) to verify the seam is wired for that controller, rather than inventing IDs that return 404.
      WIRED_ENDPOINTS = [
        { path: "/lakeraven-ehr/Patient", method: :get, params: { name: "Anderson" } },
        { path: "/lakeraven-ehr/Patient/1", method: :get },
        # POST /Patient requires an RPC response to register a patient, which isn't seeded data
        { path: "/lakeraven-ehr/Patient", method: :post, params: { resourceType: "Patient", name: [ { family: "Test" } ], gender: "female", birthDate: "1985-06-15", identifier: [ { system: "http://hl7.org/fhir/sid/us-ssn", value: "111-11-1111" } ] }.to_json, content_type: "application/fhir+json", needs_registration_stub: true },
        { path: "/lakeraven-ehr/AllergyIntolerance", method: :get, params: { patient: "1" } },
        { path: "/lakeraven-ehr/Condition", method: :get, params: { patient: "1" } },
        { path: "/lakeraven-ehr/MedicationRequest", method: :get, params: { patient: "1" } },
        { path: "/lakeraven-ehr/Observation", method: :get, params: { patient: "1" } },
        { path: "/lakeraven-ehr/Encounter", method: :get, params: { patient: "1" } },
        { path: "/lakeraven-ehr/ServiceRequest", method: :get, params: { patient: "1" } },
        { path: "/lakeraven-ehr/Immunization", method: :get, params: { patient: "1" } },
        { path: "/lakeraven-ehr/Procedure", method: :get, params: { patient: "1" } },
        { path: "/lakeraven-ehr/CoverageEligibilityRequest", method: :post, params: { patient_dfn: "1", coverage_type: "medicaid" } },
        { path: "/lakeraven-ehr/MeasureReport", method: :get, params: { patient: "1" } },
        { path: "/lakeraven-ehr/Consent", method: :get, params: { patient: "1" } },
        { path: "/lakeraven-ehr/AuditEvent", method: :get },
        { name: "AuditEvent show", dynamic_path: -> { "/lakeraven-ehr/AuditEvent/#{@audit_event.id}" }, method: :get },
        { name: "exports file show", dynamic_path: -> { @export_file_path }, method: :get },
        { path: "/lakeraven-ehr/patients/1.json", method: :get },
        { path: "/lakeraven-ehr/patients/1/screenings", method: :get, session_auth: true,
          setup: -> {
            app = Doorkeeper::Application.find_or_create_by!(name: Lakeraven::EHR::SmartAuthentication::BROWSER_SSO_APP_NAME) do |a|
              a.redirect_uri = "https://example.test/callback"
              a.scopes = "user/QuestionnaireResponse.read user/QuestionnaireResponse.write"
              a.confidential = true
            end
            #

            token = Doorkeeper::AccessToken.create!(
              application: app,
              scopes: "user/QuestionnaireResponse.read user/QuestionnaireResponse.write",
              resource_owner_id: "99999",
              expires_in: 3600
            )
            token.update_column(:browser_session, true) if token.has_attribute?(:browser_session)

            post "/lakeraven-ehr/test_session", params: {
              duz: "99999", user_type: "provider",
              smart_token: token.plaintext_token || token.token
            }

            # Like ScreeningsControllerTest: the patient-context POST needs a real CSRF token.
            @forgery_was = ActionController::Base.allow_forgery_protection if @forgery_was.nil?
            ActionController::Base.allow_forgery_protection = true
            get "/lakeraven-ehr/login"
            csrf_token = css_select("meta[name=csrf-token]").first&.[]("content")

            post "/lakeraven-ehr/patients/1/context", params: { authenticity_token: csrf_token }

            Lakeraven::EHR::ScreeningResponse.where(patient_dfn: "1").delete_all
            Lakeraven::EHR::ScreeningResponse.create!(
              patient_dfn: "1",
              encounter_ien: "2090061",
              instrument_key: "phq-9",
              answers: Lakeraven::EHR::ScreeningInstrument::PHQ9.link_ids.index_with { 1 },
              total_score: 9,
              severity_band: "mild",
              effective_at: Time.utc(2026, 3, 1),
              source: "clinician",
              administered_by: "99999",
              safety_flagged: true,
              safety_acknowledged_at: Time.utc(2026, 3, 1),
              safety_acknowledged_by: "99999"
            )
          }
        },
        { name: "screenings show", dynamic_path: -> { "/lakeraven-ehr/patients/1/screenings/#{(Lakeraven::EHR::ScreeningResponse.last&.id || 1)}" }, method: :get, session_auth: true,
          setup: -> {
            app = Doorkeeper::Application.find_or_create_by!(name: Lakeraven::EHR::SmartAuthentication::BROWSER_SSO_APP_NAME) do |a|
              a.redirect_uri = "https://example.test/callback"
              a.scopes = "user/QuestionnaireResponse.read user/QuestionnaireResponse.write"
              a.confidential = true
            end
            #

            token = Doorkeeper::AccessToken.create!(
              application: app,
              scopes: "user/QuestionnaireResponse.read user/QuestionnaireResponse.write",
              resource_owner_id: "99999",
              expires_in: 3600
            )
            token.update_column(:browser_session, true) if token.has_attribute?(:browser_session)

            post "/lakeraven-ehr/test_session", params: {
              duz: "99999", user_type: "provider",
              smart_token: token.plaintext_token || token.token
            }

            # Like ScreeningsControllerTest: the patient-context POST needs a real CSRF token.
            @forgery_was = ActionController::Base.allow_forgery_protection if @forgery_was.nil?
            ActionController::Base.allow_forgery_protection = true
            get "/lakeraven-ehr/login"
            csrf_token = css_select("meta[name=csrf-token]").first&.[]("content")

            post "/lakeraven-ehr/patients/1/context", params: { authenticity_token: csrf_token }

            Lakeraven::EHR::ScreeningResponse.where(patient_dfn: "1").delete_all
            Lakeraven::EHR::ScreeningResponse.create!(
              patient_dfn: "1",
              encounter_ien: "2090061",
              instrument_key: "phq-9",
              answers: Lakeraven::EHR::ScreeningInstrument::PHQ9.link_ids.index_with { 1 },
              total_score: 9,
              severity_band: "mild",
              effective_at: Time.utc(2026, 3, 1),
              source: "clinician",
              administered_by: "99999",
              safety_flagged: true,
              safety_acknowledged_at: Time.utc(2026, 3, 1),
              safety_acknowledged_by: "99999"
            )
          }
        }
      ].freeze

      # Medication, DiagnosticReport and CarePlan were routed with no
      # controller, and Encounter's show with no action, so each raised (#574).
      # They are not routed now. Adding one back puts its action in front of
      # the completeness test above, which then requires it to be wired or
      # allowlisted.
      %w[
        /lakeraven-ehr/Medication /lakeraven-ehr/Medication/1
        /lakeraven-ehr/DiagnosticReport /lakeraven-ehr/DiagnosticReport/1
        /lakeraven-ehr/CarePlan /lakeraven-ehr/CarePlan/1
        /lakeraven-ehr/Encounter/1
      ].each do |path|
        test "#{path} is not routed and serves nothing" do
          get path, params: { patient: "1" }, headers: @headers

          assert_response :not_found
          refute_includes response.body, "Anderson", "Expected not to serve patient data"
        end
      end

      [
        [ "/lakeraven-ehr/AllergyIntolerance/1", { patient: "1" } ],
        [ "/lakeraven-ehr/Condition/1", { patient: "1" } ],
        [ "/lakeraven-ehr/MedicationRequest/1", { patient: "1" } ],
        [ "/lakeraven-ehr/Observation/1", { patient: "1" } ],
        [ "/lakeraven-ehr/Consent/1", { patient: "1" } ]
      ].each do |path, params|
        test "stubbed action for #{path} does not serve data and fails if implemented without wiring" do
          begin
            get path, params: params, headers: @headers
          rescue ActionController::RoutingError, ActionDispatch::MissingController, NameError, AbstractController::ActionNotFound
            assert true
          else
            assert_response :not_found, "The action for #{path} was implemented but not moved to WIRED_ACTIONS in the test. If it is real, you must wire it to Part2EgressFilter and move it to WIRED_ACTIONS."
            refute_includes response.body, "Anderson", "Expected not to serve patient data"
          end
        end
      end

      test "HTML chart calls Part2EgressFilter and reflects filter output" do
        # 1. Verify it appears with the real filter
        get "/lakeraven-ehr/patients/1", headers: @headers
        assert_response :success
        assert_includes response.body, "120/80"

        # 2. Mock filter to return an empty bundle and verify it's gone
        calls = 0
        stub_egress_filter(->(payload) {
          calls += 1
          { "resourceType" => "Bundle", "type" => "searchset", "entry" => [] }
        }) do
          get "/lakeraven-ehr/patients/1", headers: @headers
        end

        assert_response :success
        assert_operator calls, :>=, 1, "HTML chart must invoke Part2EgressFilter"
        refute_includes response.body, "120/80", "Expected clinical content to be removed when filter returns empty bundle"
      end

      test "HTML chart fails closed if seam returns nil" do
        stub_egress_filter(->(payload) { nil }) do
          get "/lakeraven-ehr/patients/1", headers: @headers
        end

        assert_response :service_unavailable
        refute_includes response.body, "120/80"
      end

      test "screenings never invent a score when filter removes the score Observation" do
        endpoint = WIRED_ENDPOINTS.find { |e| e[:name] == "screenings show" }
        instance_exec(&endpoint[:setup])
        path = instance_exec(&endpoint[:dynamic_path])

        stub_egress_filter(->(payload) {
          if payload.is_a?(Hash)
            payload = payload.deep_dup.deep_stringify_keys
            if payload["resourceType"] == "Bundle"
              payload["entry"].reject! { |e| e.dig("resource", "resourceType") == "Observation" }

              # Also remove PHQ-9 item 9 to test safety flag
              q_response = payload["entry"].find { |e| e.dig("resource", "resourceType") == "QuestionnaireResponse" }
              if q_response && q_response["resource"]["item"]
                q_response["resource"]["item"].reject! { |item| item["linkId"] == Lakeraven::EHR::ScreeningInstrument::PHQ9.safety_link_id }
              end
            end
          end
          payload
        }) do
          get path
        end

        assert_response :success
        # Score should be withheld
        assert_select ".screening-score__total", text: /9/, count: 0
        assert_select ".screening-score__number", text: /9/, count: 0
        assert_select "tfoot tr td", text: /9/, count: 0
        assert_select ".screening-score__band", text: /Mild/, count: 0
        assert_select ".screening-score__total", text: /Withheld/

        # Safety flag should not be derived from partial answers
        refute_includes response.body, "Self-harm response recorded"
      end
      test "the screenings self-harm banner is not shown when filter changes item 9 answer to zero-valued choice" do
        endpoint = WIRED_ENDPOINTS.find { |e| e[:name] == "screenings show" }
        instance_exec(&endpoint[:setup])
        path = instance_exec(&endpoint[:dynamic_path])

        stub_egress_filter(->(payload) {
          if payload.is_a?(Hash)
            payload = payload.deep_dup.deep_stringify_keys
            if payload["resourceType"] == "Bundle"
              q_response = payload["entry"].find { |e| e.dig("resource", "resourceType") == "QuestionnaireResponse" }
              if q_response && q_response["resource"]["item"]
                item9 = q_response["resource"]["item"].find { |item| item["linkId"] == Lakeraven::EHR::ScreeningInstrument::PHQ9.safety_link_id }
                if item9 && item9["answer"] && item9["answer"].first
                  item9["answer"].first["valueInteger"] = 0
                end
              end
            end
          end
          payload
        }) do
          get path
        end

        assert_response :success
        refute_includes response.body, "Self-harm response recorded"
      end

      test "the screenings self-harm banner is shown when filter keeps item 9 with nonzero answer" do
        endpoint = WIRED_ENDPOINTS.find { |e| e[:name] == "screenings show" }
        instance_exec(&endpoint[:setup])
        path = instance_exec(&endpoint[:dynamic_path])

        stub_egress_filter(->(payload) {
          if payload.is_a?(Hash)
            payload = payload.deep_dup.deep_stringify_keys
            if payload["resourceType"] == "Bundle"
              q_response = payload["entry"].find { |e| e.dig("resource", "resourceType") == "QuestionnaireResponse" }
              if q_response && q_response["resource"]["item"]
                item9 = q_response["resource"]["item"].find { |item| item["linkId"] == Lakeraven::EHR::ScreeningInstrument::PHQ9.safety_link_id }
                if item9 && item9["answer"] && item9["answer"].first
                  item9["answer"].first["valueInteger"] = 1
                end
              end
            end
          end
          payload
        }) do
          get path
        end

        assert_response :success
        assert_includes response.body, "Self-harm response recorded"
      end


      WIRED_ENDPOINTS.each do |endpoint|
        test_name = endpoint[:name] || endpoint[:path]

        test "seam is invoked and response reflects change for #{endpoint[:method].to_s.upcase} #{test_name}" do
          instance_exec(&endpoint[:setup]) if endpoint[:setup]
          path = endpoint[:dynamic_path] ? instance_exec(&endpoint[:dynamic_path]) : endpoint[:path]

          is_html = path.include?("/patients/") && !path.end_with?(".json")

          call_proc = -> {
            if endpoint[:method] == :post
              post path, params: endpoint[:params], headers: @headers.merge("Content-Type" => endpoint[:content_type] || "application/x-www-form-urlencoded")
            else
              get path, params: endpoint[:params], headers: (endpoint[:session_auth] ? {} : @headers)
            end
          }

          if is_html
            if endpoint[:needs_registration_stub]
              with_registration_success(&call_proc)
            else
              call_proc.call
            end
            assert_response :success
            assert_includes response.body, "Mild", "Expected seeded data (mild) to appear before filtering"

            calls = 0
            stub_egress_filter(->(payload) {
              calls += 1
              { "resourceType" => "Bundle", "type" => "searchset", "entry" => [] }
            }) do
              if endpoint[:needs_registration_stub]
                with_registration_success(&call_proc)
              else
                call_proc.call
              end
            end

            assert_response :success, "Expected successful response but got #{response.status}. Body: #{response.body}"
            assert_operator calls, :>=, 1, "HTML endpoint must invoke Part2EgressFilter"
            refute_includes response.body, "Mild", "Expected clinical content to be removed when filter returns empty bundle"
          else
            marker = { "resourceType" => "Basic", "id" => "FILTER-MARKER" }
            marker_ndjson = "{\"resourceType\":\"Basic\",\"id\":\"FILTER-MARKER\"}\n"

            stub_egress_filter(->(payload) {
              if payload.is_a?(String)
                marker_ndjson
              else
                marker
              end
            }) do
              if endpoint[:needs_registration_stub]
                with_registration_success(&call_proc)
              else
                call_proc.call
              end
            end

            assert_response :success, "Expected successful response but got #{response.status}. Body: #{response.body}"

            if test_name == "exports file show"
              assert_equal marker_ndjson, response.body, "Expected export file body to exactly equal the marker NDJSON"
            else
              body = JSON.parse(response.body)
              assert_equal marker, body, "Expected parsed JSON body to exactly equal the marker hash"
            end
          end
        end

        test "fails closed if seam returns nil for #{endpoint[:method].to_s.upcase} #{test_name}" do
          path = nil
          stub_egress_filter(->(payload) { nil }) do
            call_proc = -> {
              if endpoint[:method] == :post
                post path, params: endpoint[:params], headers: @headers.merge("Content-Type" => endpoint[:content_type] || "application/x-www-form-urlencoded")
              else
                get path, params: endpoint[:params], headers: (endpoint[:session_auth] ? {} : @headers)
              end
            }

            instance_exec(&endpoint[:setup]) if endpoint[:setup]
            path = endpoint[:dynamic_path] ? instance_exec(&endpoint[:dynamic_path]) : endpoint[:path]
            if endpoint[:needs_registration_stub]
              with_registration_success(&call_proc)
            else
              call_proc.call
            end
          end

          if endpoint[:method] == :post && endpoint[:needs_registration_stub]
            assert_response :created
            assert_not_nil response.headers["Location"], "Expected Location header on refused POST representation"
            body = JSON.parse(response.body)
            assert_equal "OperationOutcome", body["resourceType"]
            refute_includes response.body, "Test" # the name from the request
            refute_includes response.body, "111-11-1111"
          else
            assert_response :service_unavailable
            if test_name == "exports file show"
              refute_includes response.body, "resourceType"
            else
              body = JSON.parse(response.body)
              assert_equal "OperationOutcome", body["resourceType"]
              refute body.key?("entry")
              refute_includes response.body, "Anderson"
            end
          end
        end
      end

      private

      # Minitest 6 no longer ships minitest/mock; swap the method the same way
      # stub_egress_filter does.
      def with_registration_success
        gateway = RegistrationGateway.singleton_class
        original = gateway.instance_method(:register)
        gateway.define_method(:register) { |*, **| { success: true, dfn: 123 } }
        yield
      ensure
        gateway.define_method(:register, original)
      end

      # session_auth rows (screenings) authenticate through the browser session
      # their setup opens; the class's system bearer token would replace it.
      def stub_egress_filter(implementation)
        filter = Part2EgressFilter.singleton_class
        original = filter.instance_method(:call)
        filter.define_method(:call, &implementation)
        yield
      ensure
        filter.define_method(:call, original)
      end
    end
  end
end
