# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class FhirReadEgressTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

      setup do
        setup_smart_auth(scopes: "system/*.read system/*.write")
        
        post "/lakeraven-ehr/exports", headers: @headers
        export_body = JSON.parse(response.body)
        @export_id = export_body["id"]
        
        # Make the export produce a real output file by using the store's API to complete it
        export = ExportsController.store[@export_id]
        export.complete!([
          { "type" => "Patient", "file_name" => "patient.ndjson", "content" => "{\"resourceType\":\"Patient\",\"name\":[{\"family\":\"Anderson\"}]}\n", "count" => 1, "url" => "http://www.example.com/lakeraven-ehr/exports/#{@export_id}/files/patient.ndjson" }
        ])
        @export_file = "patient.ndjson"

        @audit_event = AuditEvent.create!(
          event_type: "rest", action: "R", outcome: "0",
          entity_type: "Patient", entity_identifier: "1"
        )
      end

      teardown do
        teardown_smart_auth
      end

      # Routed but NO controller exists on origin/main.
      # When implemented, they must be wired to Part2EgressFilter.
      UNIMPLEMENTED_ACTIONS = [
        "lakeraven/ehr/medications#index",
        "lakeraven/ehr/medications#show",
        "lakeraven/ehr/diagnostic_reports#index",
        "lakeraven/ehr/diagnostic_reports#show",
        "lakeraven/ehr/care_plans#index",
        "lakeraven/ehr/care_plans#show"
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
        "lakeraven/ehr/screenings#index",     # Session-authenticated clinician UI
        "lakeraven/ehr/screenings#create",    # Session-authenticated clinician UI
        "lakeraven/ehr/screenings#new",       # Session-authenticated clinician UI
        "lakeraven/ehr/screenings#show",      # Session-authenticated clinician UI
        "lakeraven/ehr/sessions#new",         # Web UI login
        "lakeraven/ehr/sessions#create",      # Web UI login
        "lakeraven/ehr/sessions#destroy",     # Web UI logout
        "lakeraven/ehr/dashboards#show",      # Web UI dashboard
        "lakeraven/ehr/test_sessions#create", # Test only
        "lakeraven/ehr/smart_configuration#show", # Discovery
        "lakeraven/ehr/smart_launch#show",    # Discovery
        "lakeraven/ehr/backend_services#token", # Auth
        "lakeraven/ehr/transitions_of_care#create", # Wired separately in #568
        "lakeraven/ehr/ccda_imports#create",  # Ingress
        "lakeraven/ehr/exports#create",       # Status/kickoff, no clinical data
        "lakeraven/ehr/exports#show",         # Status/kickoff
        "lakeraven/ehr/exports#destroy",      # Status/kickoff
        "lakeraven/ehr/patient_contexts#create", # Session context
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
        "lakeraven/ehr/allergy_intolerances#index",
        "lakeraven/ehr/allergy_intolerances#show",
        "lakeraven/ehr/conditions#index",
        "lakeraven/ehr/conditions#show",
        "lakeraven/ehr/medication_requests#index",
        "lakeraven/ehr/medication_requests#show",
        "lakeraven/ehr/observations#index",
        "lakeraven/ehr/observations#show",
        "lakeraven/ehr/encounters#index",
        "lakeraven/ehr/encounters#show",
        "lakeraven/ehr/service_requests#index",
        "lakeraven/ehr/immunizations#index",
        "lakeraven/ehr/procedures#index",
        "lakeraven/ehr/coverage_eligibility_requests#create",
        "lakeraven/ehr/measure_reports#index",
        "lakeraven/ehr/consents#index",
        "lakeraven/ehr/consents#show",
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
        
        untested = controller_actions - ALLOWED_WITHOUT_SEAM - WIRED_ACTIONS - UNIMPLEMENTED_ACTIONS
        
        assert_empty untested, "Found routes that might disclose clinical data but are not explicitly tested for seam wiring or allowlisted."
      end

      # Table-driven tests for each wired endpoint that can be successfully invoked with seeded data.
      # Note: Many /:id show routes (like Consent/:id, AllergyIntolerance/:id) are omitted here because 
      # we do not have seeded data for those specific resource IDs. We use the nearest real path 
      # (the index search route) to verify the seam is wired for that controller, rather than inventing IDs that return 404.
      WIRED_ENDPOINTS = [
        { path: "/lakeraven-ehr/Patient", method: :get, params: { name: "Anderson" } },
        { path: "/lakeraven-ehr/Patient/1", method: :get },
        # POST /Patient requires an RPC response to register a patient, which isn't seeded data
        { path: "/lakeraven-ehr/Patient", method: :post, params: { resourceType: "Patient", name: [{ family: "Test" }], gender: "female", birthDate: "1985-06-15", identifier: [{system: "http://hl7.org/fhir/sid/us-ssn", value: "111-11-1111"}] }.to_json, content_type: "application/fhir+json", needs_registration_stub: true },
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
        { name: "exports file show", dynamic_path: -> { "/lakeraven-ehr/exports/#{@export_id}/files/#{@export_file}" }, method: :get },
        { path: "/lakeraven-ehr/patients/1.json", method: :get }
      ].freeze

      [
        ["/lakeraven-ehr/Medication", { patient: "1" }],
        ["/lakeraven-ehr/DiagnosticReport", { patient: "1" }],
        ["/lakeraven-ehr/CarePlan", { patient: "1" }]
      ].each do |path, params|
        test "missing controller for #{path} does not serve data and fails if later added without wiring" do
          begin
            get path, params: params, headers: @headers
          rescue ActionController::RoutingError, ActionDispatch::MissingController, NameError, AbstractController::ActionNotFound
            # Pass: The controller doesn't exist, which is expected for now.
            assert true
          else
            refute_response :success, "The controller for #{path} was added. You must wire it to Part2EgressFilter and move it to WIRED_ACTIONS in the test."
            refute_includes response.body, "Anderson", "Expected not to serve patient data"
          end
        end
      end

      WIRED_ENDPOINTS.each do |endpoint|
        test_name = endpoint[:name] || endpoint[:path]
        
        test "seam is invoked and response reflects change for #{endpoint[:method].to_s.upcase} #{test_name}" do
          path = endpoint[:dynamic_path] ? instance_exec(&endpoint[:dynamic_path]) : endpoint[:path]

          marker = { "resourceType" => "Basic", "id" => "FILTER-MARKER" }
          
          stub_egress_filter(->(payload) { 
            if payload.is_a?(String)
              '{"resourceType":"Basic","id":"FILTER-MARKER"}'
            else
              marker 
            end
          }) do
            call_proc = -> {
              if endpoint[:method] == :post
                post path, params: endpoint[:params], headers: @headers.merge("Content-Type" => endpoint[:content_type] || "application/x-www-form-urlencoded")
              else
                get path, params: endpoint[:params], headers: @headers
              end
            }

            if endpoint[:needs_registration_stub]
              with_registration_success(&call_proc)
            else
              call_proc.call
            end
          end

          assert_response :success, "Expected successful response but got #{response.status}. Body: #{response.body}"
          assert_includes response.body, "FILTER-MARKER", "Expected response to reflect the filter's output"
        end

        test "fails closed if seam returns nil for #{endpoint[:method].to_s.upcase} #{test_name}" do
          path = endpoint[:dynamic_path] ? instance_exec(&endpoint[:dynamic_path]) : endpoint[:path]

          stub_egress_filter(->(payload) { nil }) do
            call_proc = -> {
              if endpoint[:method] == :post
                post path, params: endpoint[:params], headers: @headers.merge("Content-Type" => endpoint[:content_type] || "application/x-www-form-urlencoded")
              else
                get path, params: endpoint[:params], headers: @headers
              end
            }

            if endpoint[:needs_registration_stub]
              with_registration_success(&call_proc)
            else
              call_proc.call
            end
          end

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
