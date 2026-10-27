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
    end
  end
end
