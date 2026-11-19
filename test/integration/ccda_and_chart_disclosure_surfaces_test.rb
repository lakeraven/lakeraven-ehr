# frozen_string_literal: true

require "test_helper"
require_relative "../dummy/lib/lakeraven_demo_seeds"

module Lakeraven
  module EHR
    # #969: C-CDA import, transitions of care and the chart's FHIR
    # representation answer as closed (a bare 404) until the host names their
    # surfaces in config.x.lakeraven_ehr.open_disclosure_surfaces. The HTML
    # chart of a signed-in browser session is not a disclosure surface.
    class CcdaAndChartDisclosureSurfacesTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

      ABSENT = Object.new.freeze
      ALL = %i[fhir_api bulk_export ccda].freeze
      TOC = "/lakeraven-ehr/transitions_of_care"
      IMPORTS = "/lakeraven-ehr/ccda_imports"
      FHIR_TYPE = "application/fhir+json"

      # [ path, label, configured value, status with no Authorization header ]
      CCDA_ROWS = [
        [ TOC,     "the key is absent (closed by default)", ABSENT,                 :not_found ],
        [ TOC,     "only other surfaces are named",         %i[fhir_api bulk_export], :not_found ],
        [ TOC,     "the value is a bare name, not a list",  :ccda,                  :not_found ],
        [ TOC,     "ccda is opened by name",                %i[ccda],               :unauthorized ],
        [ TOC,     "every surface is opened by name",       ALL,                    :unauthorized ],
        [ IMPORTS, "the key is absent (closed by default)", ABSENT,                 :not_found ],
        [ IMPORTS, "only ccda is named",                    %i[ccda],               :not_found ],
        [ IMPORTS, "only fhir_api is named",                %i[fhir_api],           :not_found ],
        [ IMPORTS, "only bulk_export is named",             %i[bulk_export],        :not_found ],
        [ IMPORTS, "the value is a bare name, not a list",  :ccda,                  :not_found ],
        [ IMPORTS, "ccda and fhir_api are both named",      %i[ccda fhir_api],      :unauthorized ],
        [ IMPORTS, "every surface is opened by name",       ALL,                    :unauthorized ]
      ].freeze

      # [ label, path, extra headers ]: every way to ask the chart for FHIR.
      CHART_FHIR_FORMS = [
        [ ".json",                  "/patients/1.json",         {} ],
        [ "?_format=json",          "/patients/1?_format=json", {} ],
        [ "Accept: #{FHIR_TYPE}",   "/patients/1",              { "Accept" => FHIR_TYPE } ]
      ].freeze

      # Counts every entry into the throttle's two writers, so a request that
      # never reached the limiter is told apart from one it counted.
      module RateLimitProbe
        class << self
          attr_accessor :calls
        end
        self.calls = 0

        def permit?(**)
          RateLimitProbe.calls += 1
          super
        end

        def audit_due?(**)
          RateLimitProbe.calls += 1
          super
        end
      end

      # [ label, configured value, "View as FHIR" offered ]
      BROWSER_ROWS = [
        [ "every surface is closed",          ABSENT,               false ],
        [ "only ccda and bulk_export are open", %i[ccda bulk_export], false ],
        [ "only fhir_api is open",            %i[fhir_api],         true ]
      ].freeze

      setup do
        @saved_options = Rails.application.config.x.lakeraven_ehr
        @original_client = RpmsRpc.configuration.client
        @broker = RpmsRpc.mock! { |m| LakeravenDemoSeeds.seed(m) }
        RateLimit.singleton_class.prepend(RateLimitProbe) unless RateLimit.singleton_class < RateLimitProbe
        RateLimit.reset!
        @work_before = nil
      end

      teardown do
        Rails.application.config.x.lakeraven_ehr = @saved_options
        RpmsRpc.configure { |c| c.client = @original_client }
        RateLimit.reset!
        teardown_smart_auth
      end

      CCDA_ROWS.each do |path, label, value, status|
        test "POST #{path} with no token answers #{status} when #{label}" do
          configure(value)
          post path, params: { patient_dfn: "1" }
          assert_response status
          status == :not_found ? assert_closed : assert_not_empty(response.body)
        end
      end

      test "closed transitions of care answers a bare 404 to a fully scoped token and renders no C-CDA" do
        setup_smart_auth(scopes: "system/*.read system/*.write")
        configure(%i[fhir_api bulk_export])
        post TOC, params: { patient_dfn: "1" }, headers: @headers
        assert_closed
        assert_not_includes response.body, "ClinicalDocument"
      end

      test "transitions of care opened by name serves a scoped token" do
        setup_smart_auth(scopes: "system/*.read system/*.write")
        configure(%i[ccda])
        post TOC, params: { patient_dfn: "1" }, headers: @headers
        assert_response :created
        assert_includes response.body, "ClinicalDocument"
      end

      [ [ "only ccda", %i[ccda], :not_found ], [ "only fhir_api", %i[fhir_api], :not_found ],
        [ "ccda and fhir_api", %i[ccda fhir_api], :bad_request ] ].each do |label, value, status|
        test "C-CDA import of an empty body with a scoped token answers #{status} when #{label} is open" do
          setup_smart_auth(scopes: "system/*.read system/*.write")
          configure(value)
          post IMPORTS, params: "", headers: @headers.merge("Content-Type" => "application/xml")
          assert_response status
          status == :not_found ? assert_closed : assert_includes(response.body, "OperationOutcome")
        end
      end

      CHART_FHIR_FORMS.each do |label, path, extra|
        test "the chart as FHIR (#{label}) is a bare 404 to a full read token while fhir_api is closed" do
          setup_smart_auth(scopes: "system/*.read")
          configure(%i[ccda bulk_export])
          get path, headers: @headers.merge(extra)
          assert_closed
        end

        test "the chart as FHIR (#{label}) is a bare 404 to a browser session while fhir_api is closed" do
          sign_in_browser
          configure(ABSENT)
          get path, headers: extra
          assert_closed
        end

        test "the chart as FHIR (#{label}) serves a Bundle when only fhir_api is open" do
          setup_smart_auth(scopes: "system/*.read")
          configure(%i[fhir_api])
          get path, headers: @headers.merge(extra)
          assert_response :ok
          assert_equal "Bundle", JSON.parse(response.body)["resourceType"]
        end
      end

      test "an HTML chart read carrying a bearer token is fhir_api: bare 404 while closed, served when open" do
        setup_smart_auth(scopes: "system/*.read")
        configure(%i[ccda bulk_export])
        get "/patients/1", headers: @headers
        assert_closed

        configure(%i[fhir_api])
        get "/patients/1", headers: @headers
        assert_response :ok
        assert_includes response.body, "View as FHIR"
      end

      BROWSER_ROWS.each do |label, value, link|
        test "the HTML chart renders for a browser session when #{label} (View as FHIR offered: #{link})" do
          sign_in_browser
          configure(value)
          get "/patients/1"
          assert_response :ok
          assert_equal "text/html", response.media_type
          assert_includes response.body, %(id="chart-problems")
          assert_equal link, response.body.include?("View as FHIR")
        end
      end

      test "a non-Bearer Authorization header does not close the browser session's HTML chart" do
        sign_in_browser
        configure(ABSENT)
        get "/patients/1", headers: { "Authorization" => "Basic c3ludGhldGljOnVzZXI=" }
        assert_response :ok
        assert_includes response.body, %(id="chart-problems")
      end

      test "transitions of care declares ccda and nothing else, for a bearer client too" do
        rules = TransitionsOfCareController.disclosure_surface_rules
        assert_equal [ :ccda ], surfaces(TransitionsOfCareController).uniq
        assert_includes unconditional_surfaces(TransitionsOfCareController), :ccda
        bearer = rules.select { |rule| rule[:key] == SmartAuthentication::BEARER_RULE_KEY }
        assert_equal [ :ccda ], bearer.map { |rule| rule[:surface] }
      end

      test "C-CDA import declares ccda and fhir_api unconditionally" do
        assert_empty %i[ccda fhir_api] - unconditional_surfaces(CcdaImportsController)
      end

      test "the chart declares fhir_api under a predicate it defines" do
        conditional = ChartsController.disclosure_surface_rules.select { |rule| rule[:surface] == :fhir_api && rule[:if] }
        assert_not_empty conditional
        conditional.each do |rule|
          assert_kind_of Symbol, rule[:if]
          assert ChartsController.method_defined?(rule[:if]) || ChartsController.private_method_defined?(rule[:if]),
                 "#{rule[:if]} is not a ChartsController method"
        end
      end

      test "the C-CDA routes are gated without an allowlist and are not listed as ungoverned" do
        routes = %w[lakeraven/ehr/ccda_imports#create lakeraven/ehr/transitions_of_care#create]
        drawn = EHR::Engine.routes.routes.map { |route| "#{route.defaults[:controller]}##{route.defaults[:action]}" }
        assert_empty routes - drawn, "the engine no longer draws these routes"
        assert_empty routes & DisclosureSurfaces.ungated_routes(EHR::Engine.routes, allow: [])
        assert_empty routes & DisclosureSurfaces::UNGOVERNED_API_ROUTES.keys
      end

      # assert_closed compares these recorders across the request. Each must be
      # seen to move for a request that is served, or "unchanged" proves nothing.
      test "the work recorders see a served chart read: throttle, broker and audit" do
        setup_smart_auth(scopes: "system/*.read")
        configure(%i[fhir_api])
        get "/patients/1.json", headers: @headers
        assert_response :ok
        after = work_snapshot
        assert_operator after[:rate_limit_calls], :>, @work_before[:rate_limit_calls]
        assert_operator after[:rate_limit_buckets], :>, @work_before[:rate_limit_buckets]
        assert_operator after[:broker_calls], :>, @work_before[:broker_calls]
        assert_operator after[:audit_events], :>, @work_before[:audit_events]
      end

      [ [ TOC, %i[ccda] ], [ IMPORTS, %i[ccda fhir_api] ] ].each do |path, value|
        test "the throttle recorder sees POST #{path} once its surfaces are open" do
          configure(value)
          post path, params: { patient_dfn: "1" }
          assert_response :unauthorized
          after = work_snapshot
          assert_operator after[:rate_limit_calls], :>, @work_before[:rate_limit_calls]
          assert_operator after[:rate_limit_buckets], :>, @work_before[:rate_limit_buckets]
        end
      end

      private

      def configure(value)
        options = ActiveSupport::OrderedOptions.new
        options[:open_disclosure_surfaces] = value unless value.equal?(ABSENT)
        Rails.application.config.x.lakeraven_ehr = options
      end

      # Every request snapshots the work recorders first, so assert_closed can
      # show the request it follows left them as they were.
      %i[get post].each do |verb|
        define_method(verb) do |*args, **options|
          @work_before = work_snapshot
          super(*args, **options)
        end
      end

      # A closed surface answers a bare 404 and does no work: no audit row, no
      # throttle check or counter, no broker call or context bind.
      def assert_closed
        assert_response :not_found
        assert_empty response.body
        assert @work_before, "assert_closed must follow a request made through this test's get/post"
        assert_equal @work_before, work_snapshot, "a closed surface did work"
      ensure
        @work_before = nil
      end

      def work_snapshot
        assert_same @broker, RpmsRpc.client, "the recording broker is not the configured client"
        assert_operator RateLimit.singleton_class, :<, RateLimitProbe, "the throttle probe is not installed"
        {
          audit_events: AuditEvent.count,
          rate_limit_calls: RateLimitProbe.calls,
          rate_limit_buckets: RateLimit.bucket_count,
          broker_calls: @broker.received_calls.size,
          broker_context_binds: @broker.context_binds.size
        }
      end

      def surfaces(controller)
        controller.disclosure_surface_rules.map { |rule| rule[:surface] }
      end

      def unconditional_surfaces(controller)
        controller.disclosure_surface_rules.reject { |rule| rule[:if] }.map { |rule| rule[:surface] }
      end

      # A signed-in clinician: the SMART token rides the session, as the
      # sign-on bridge leaves it, and no Authorization header is sent.
      def sign_in_browser(scopes: "user/*.read")
        app = Doorkeeper::Application.create!(
          name: SmartAuthentication::BROWSER_SSO_APP_NAME,
          redirect_uri: "https://example.test/callback", scopes: scopes, confidential: true
        )
        token = Doorkeeper::AccessToken.create!(
          application: app, scopes: scopes, resource_owner_id: "99999", expires_in: 3600
        )
        token.update_column(:browser_session, true) if token.has_attribute?(:browser_session)
        post "/lakeraven-ehr/test_session",
             params: { duz: "99999", user_type: "provider", smart_token: token.plaintext_token || token.token }
        assert_response :ok
      end
    end
  end
end
