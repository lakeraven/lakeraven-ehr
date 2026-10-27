# frozen_string_literal: true

require "test_helper"
require_relative "../../../dummy/lib/lakeraven_demo_seeds"
require_relative "../../../support/allergy_write_test_helper"

module Lakeraven
  module EHR
    # Server-rendered allergy entry from the chart (#644). Same credential and
    # patient-context story as ScreeningsController (#486).
    class AllergiesControllerTest < ActionDispatch::IntegrationTest
      include AllergyWriteTestHelper

      DFN = "3"
      BASE = "/lakeraven-ehr/patients/#{DFN}/allergies"
      NKA_PATH = "/lakeraven-ehr/patients/#{DFN}/allergies/no_known_allergies"
      CHART = "/lakeraven-ehr/patients/#{DFN}"

      setup do
        @forgery_was = ActionController::Base.allow_forgery_protection
        ActionController::Base.allow_forgery_protection = true
        Lakeraven::EHR::AuditEvent.delete_all
        @demo_original_client = RpmsRpc.configuration.client
        RpmsRpc.mock! { |m| LakeravenDemoSeeds.seed(m) }
        sign_in_clinician!(scopes: WRITE_SCOPES)
        open_patient_context!(DFN)
        @tracker = TrackingAllergyGateway.new
      end

      teardown do
        ActionController::Base.allow_forgery_protection = @forgery_was
        teardown_oauth!
        Lakeraven::EHR::AuditEvent.delete_all
        if @demo_original_client
          RpmsRpc.configure { |c| c.client = @demo_original_client }
          @demo_original_client = nil
        end
      end

      def token_for(scopes:, duz: DUZ, app_name: SmartAuthentication::BROWSER_SSO_APP_NAME)
        clinician_token(scopes: scopes, duz: duz, app_name: app_name)
      end

      def patient_token(dfn: DFN, scopes: "patient/AllergyIntolerance.read patient/AllergyIntolerance.write")
        token_for(scopes: scopes, duz: dfn, app_name: "smart-patient-app")
      end

      def system_token(scopes: "system/AllergyIntolerance.read system/AllergyIntolerance.write")
        token_for(scopes: scopes, duz: nil, app_name: "backend-service")
      end

      def auth_headers(token = nil)
        return {} if token.nil?

        { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }
      end

      def with_failing(klass, method, replacement)
        singleton = klass.singleton_class
        original = singleton.instance_method(method) if singleton.method_defined?(method)
        original = nil unless original&.owner == singleton

        klass.define_singleton_method(method, &replacement)
        yield
      ensure
        singleton.send(:remove_method, method)
        singleton.send(:define_method, method, original) if original
      end

      def with_broken_audit(&block)
        with_failing(AuditEvent, :create!, ->(*) { raise ActiveRecord::StatementInvalid, "audit down" }, &block)
      end

      def post_allergy(extra = {})
        with_tracking_allergy_gateway(@tracker) do
          post BASE, params: allergy_form_params(extra).merge(authenticity_token: csrf_token)
        end
      end

      def post_nka
        with_tracking_allergy_gateway(@tracker) do
          post NKA_PATH, params: { authenticity_token: csrf_token }
        end
      end

      def follow_chart_redirect!
        follow_redirect!
        setup_chart_bearer!
        get CHART, headers: @chart_headers
      end

      # -- Chart entry points ---------------------------------------------------

      test "chart shows link to record an allergy and POST form for no known allergies" do
        setup_chart_bearer!
        get CHART, headers: @chart_headers

        assert_response :ok
        assert_select "a[href=?]", "#{MOUNT}/patients/#{DFN}/allergies/new", text: /record.*allergy/i
        assert_select "form[action=?][method=post]", NKA_PATH
        nka_forms = css_select("form[action='#{NKA_PATH}'][method=post]")
        submits = nka_forms.flat_map { |form| form.css("input[type=submit], button[type=submit]") }
        assert submits.any? { |node| (node["value"] || node.text).match?(/no known allergies/i) },
               "expected NKA form submit control labeled No known allergies"
        assert_select "a[href=?]", NKA_PATH, count: 0
      end

      test "GET no known allergies path does not record NKA" do
        setup_chart_bearer!

        with_tracking_allergy_gateway(@tracker) do
          get NKA_PATH, headers: @chart_headers
        end

        assert_includes [ 301, 302, 303, 307, 308, 404, 405 ], response.status
        assert_empty @tracker.nka_calls
      end

      # -- New form -------------------------------------------------------------

      test "GET new allergy form renders" do
        get "#{BASE}/new"

        assert_response :ok
        assert_select "form[action=?]", BASE
        assert_select "input[name=?]", "allergy[agent]"
      end

      # -- Successful writes ----------------------------------------------------

      test "POST allergy with valid synthetic data calls gateway once and redirects with success notice" do
        post_allergy

        assert_equal 1, @tracker.add_calls.length
        assert_redirected_to CHART
        follow_redirect!
        assert_match(/recorded|saved/i, response.body)
        refute_match(/not saved/i, response.body)
      end

      test "POST no known allergies calls gateway once and redirects with success notice" do
        post_nka

        assert_equal 1, @tracker.nka_calls.length
        assert_redirected_to CHART
        follow_redirect!
        assert_match(/recorded|saved|no known/i, response.body)
      end

      test "originator request param is ignored in favor of clinician DUZ" do
        post_allergy(originator: "00001")

        call = @tracker.add_calls.first
        assert_equal DUZ, call[:clinician_duz].to_s
        attrs = call[:attrs]
        refute_equal "00001", attrs[:originator].to_s
        refute_equal "00001", attrs["originator"].to_s
      end

      # -- Gateway failure ------------------------------------------------------

      test "POST allergy re-renders form with error when gateway fails" do
        @tracker = TrackingAllergyGateway.new(add_returns: { success: false, error: :backend, message: "failed" })

        post_allergy

        assert_response :unprocessable_entity
        assert_match(/not saved/i, response.body)
        refute_match(/\bsaved\b/i, response.body.gsub(/not saved/i, ""))
        assert_select "form[action=?]", BASE
      end

      test "POST NKA shows error when gateway fails" do
        @tracker = TrackingAllergyGateway.new(nka_returns: { success: false, error: :backend, message: "failed" })

        post_nka

        assert_response :unprocessable_entity
        assert_match(/not (saved|recorded)/i, response.body)
      end

      # -- Credential and scope -------------------------------------------------

      test "no token refuses create and does not call gateway" do
        reset!

        with_tracking_allergy_gateway(@tracker) do
          post BASE, params: allergy_form_params.merge(authenticity_token: csrf_token)
        end

        assert_response :unauthorized
        assert_empty @tracker.add_calls
      end

      test "token without allergy write scope refuses create" do
        sign_in_clinician!(scopes: READ_SCOPES)
        open_patient_context!(DFN)

        with_tracking_allergy_gateway(@tracker) do
          post BASE, params: allergy_form_params.merge(authenticity_token: csrf_token)
        end

        assert_response :forbidden
        assert_empty @tracker.add_calls
      end

      test "patient-scoped token cannot record an allergy" do
        patient = patient_token

        with_tracking_allergy_gateway(@tracker) do
          post BASE,
               params: allergy_form_params.merge(authenticity_token: csrf_token),
               headers: auth_headers(patient)
        end

        assert_response :forbidden
        assert_empty @tracker.add_calls
      end

      test "system token cannot record an allergy" do
        with_tracking_allergy_gateway(@tracker) do
          post BASE,
               params: allergy_form_params.merge(authenticity_token: csrf_token),
               headers: auth_headers(system_token)
        end

        assert_response :forbidden
        assert_empty @tracker.add_calls
      end

      test "recording for a patient the session never opened is refused" do
        reset!
        sign_in_clinician!(scopes: WRITE_SCOPES)

        with_tracking_allergy_gateway(@tracker) do
          post BASE, params: allergy_form_params.merge(authenticity_token: csrf_token)
        end

        assert_response :forbidden
        assert_empty @tracker.add_calls
      end

      test "recording for another patient while context is open on a different patient is refused" do
        open_patient_context!("2")

        with_tracking_allergy_gateway(@tracker) do
          post BASE, params: allergy_form_params.merge(authenticity_token: csrf_token)
        end

        assert_response :forbidden
        assert_empty @tracker.add_calls
      end

      test "missing CSRF token refuses create" do
        with_tracking_allergy_gateway(@tracker) do
          post BASE, params: allergy_form_params
        end

        assert_includes [ 403, 422 ], response.status
        assert_empty @tracker.add_calls
      end

      # -- Audit ----------------------------------------------------------------

      test "successful allergy create is audited as success" do
        AuditEvent.delete_all

        assert_difference -> { AuditEvent.count }, 1 do
          post_allergy
        end

        event = AuditEvent.recent.first
        assert_equal "C", event.action
        assert_equal "0", event.outcome
        assert_equal DUZ, event.agent_who_identifier
      end

      test "refused create is audited with failure outcome" do
        reset!
        sign_in_clinician!(scopes: WRITE_SCOPES)
        AuditEvent.delete_all
        authenticity_token = csrf_token

        assert_difference -> { AuditEvent.count }, 1 do
          with_tracking_allergy_gateway(@tracker) do
            post BASE, params: allergy_form_params.merge(authenticity_token: authenticity_token)
          end
        end

        assert_response :forbidden
        assert_equal "4", AuditEvent.recent.first.outcome
      end

      test "no allergy is written when the access cannot be recorded" do
        AuditEvent.delete_all

        with_broken_audit do
          post_allergy
        end

        assert_response :service_unavailable
        assert_empty @tracker.add_calls
        assert_equal 0, AuditEvent.count
      end

      # -- Banner refresh -------------------------------------------------------

      test "after successful add chart reload shows the new allergen in the banner" do
        post_allergy
        assert_redirected_to CHART
        seed_synthetic_allergy_row!(DFN)

        follow_chart_redirect!
        assert_response :ok
        assert_includes allergies_label_text, SYNTHETIC_AGENT
        assert_allergies_state!("loaded")
      end

      test "after successful NKA chart reload shows none recorded in the banner" do
        post_nka
        assert_redirected_to CHART
        seed_nka_allergy_assessment!(DFN)

        follow_chart_redirect!
        assert_response :ok
        assert_allergies_state!("none-recorded", text_fragment: "None recorded")
      end

      # -- Spec amendment: audit after committed RPC (#644 review) ---------------

      test "POST allergy returns 503 explaining RPMS write succeeded when post-write audit fails" do
        AuditEvent.delete_all
        logs = capture_rails_logs do
          with_audit_create_failing_after_probe do
            with_tracking_allergy_gateway(@tracker) do
              post BASE, params: allergy_form_params.merge(authenticity_token: csrf_token)
            end
          end
        end

        assert_equal 1, @tracker.add_calls.length
        assert_response :service_unavailable
        assert_match(/recorded/i, response.body)
        assert_match(/audit/i, response.body)
        refute_match(/not (completed|saved|recorded)/i, response.body)
        refute_match(/Allergy recorded\./, response.body)
        assert_error_log_without_clinical_text!(logs)
      end

      test "POST NKA returns 503 explaining RPMS write succeeded when post-write audit fails" do
        AuditEvent.delete_all
        logs = capture_rails_logs do
          with_audit_create_failing_after_probe do
            with_tracking_allergy_gateway(@tracker) do
              post NKA_PATH, params: { authenticity_token: csrf_token }
            end
          end
        end

        assert_equal 1, @tracker.nka_calls.length
        assert_response :service_unavailable
        assert_match(/recorded/i, response.body)
        assert_match(/audit/i, response.body)
        refute_match(/not (completed|saved|recorded)/i, response.body)
        refute_match(/No known allergies recorded\./, response.body)
        assert_error_log_without_clinical_text!(logs)
      end

      # -- Spec amendment: gateway refusal messaging (#644 review) -------------

      test "POST NKA with active allergies refusal explains patient has active allergies on file" do
        @tracker = TrackingAllergyGateway.new(
          nka_returns: {
            success: false,
            error: :active_allergies,
            message: BACKEND_PROBE_MESSAGE
          }
        )

        post_nka

        assert_response :unprocessable_entity
        assert_match(/active allerg/i, response.body)
        refute_backend_message_in_body!(response.body)
      end

      test "POST allergy with duplicate refusal explains allergy is already on file" do
        @tracker = TrackingAllergyGateway.new(
          add_returns: { success: false, error: :duplicate, message: BACKEND_PROBE_MESSAGE }
        )

        post_allergy

        assert_response :unprocessable_entity
        assert_match(/already|duplicate/i, response.body)
        refute_backend_message_in_body!(response.body)
      end

      test "POST allergy with unavailable outcome says to check chart and does not claim nothing changed" do
        @tracker = TrackingAllergyGateway.new(
          add_returns: { success: false, error: :unavailable, message: BACKEND_PROBE_MESSAGE }
        )

        post_allergy

        assert_response :unprocessable_entity
        assert_match(/unknown|could not confirm|check the chart/i, response.body)
        refute_match(/left unchanged/i, response.body)
        refute_match(/was not saved/i, response.body)
        refute_backend_message_in_body!(response.body)
      end

      test "POST NKA with unavailable outcome says to check chart and does not claim nothing changed" do
        @tracker = TrackingAllergyGateway.new(
          nka_returns: { success: false, error: :unavailable, message: BACKEND_PROBE_MESSAGE }
        )

        post_nka

        assert_response :unprocessable_entity
        assert_match(/unknown|could not confirm|check the chart/i, response.body)
        refute_match(/left unchanged/i, response.body)
        refute_match(/was not saved/i, response.body)
        refute_backend_message_in_body!(response.body)
      end

      test "POST allergy with generic gateway refusal reports not saved" do
        @tracker = TrackingAllergyGateway.new(
          add_returns: { success: false, error: :invalid_value, message: BACKEND_PROBE_MESSAGE }
        )

        post_allergy

        assert_response :unprocessable_entity
        assert_match(/not saved/i, response.body)
        refute_backend_message_in_body!(response.body)
      end

      test "POST NKA failure heading does not use double negative wording" do
        @tracker = TrackingAllergyGateway.new(
          nka_returns: { success: false, error: :invalid_value, message: BACKEND_PROBE_MESSAGE }
        )

        post_nka

        assert_response :unprocessable_entity
        refute_match(/No known allergies were not recorded/i, response.body)
      end

      # -- Spec amendment: indexed allergy params (#644 review) ------------------

      test "POST allergy with Rails indexed symptoms and comments passes them to gateway" do
        with_tracking_allergy_gateway(@tracker) do
          post BASE, params: indexed_allergy_form_params.merge(authenticity_token: csrf_token)
        end

        assert_equal 1, @tracker.add_calls.length
        attrs = @tracker.add_calls.first[:attrs]
        symptoms = attrs[:symptoms] || attrs["symptoms"]
        comments = attrs[:comments] || attrs["comments"]

        assert symptoms.is_a?(Array), "expected symptoms as an Array, got #{symptoms.class}"
        assert_equal SYNTHETIC_SYMPTOM, symptoms.dig(0, :text) || symptoms.dig(0, "text")
        assert comments.is_a?(Array), "expected comments as an Array, got #{comments.class}"
        assert_equal SYNTHETIC_COMMENT, comments.first
      end

      test "POST allergy with malformed symptoms shape returns 422 and does not call gateway" do
        base = valid_synthetic_allergy_attrs.except(:symptoms, :comments, :originator)
        params = {
          allergy: base.merge(symptoms: "SYNTHETIC-GARBAGE-SHAPE"),
          authenticity_token: csrf_token
        }

        with_tracking_allergy_gateway(@tracker) do
          post BASE, params: params
        end

        assert_response :unprocessable_entity
        assert_match(/not saved/i, response.body)
        assert_empty @tracker.add_calls
      end
    end
  end
end
