# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # #905 (slice of #522): the December build is MH/BH only and must not hold
    # itself out as providing SUD referral for treatment (42 CFR 2.11). The
    # control is that no referral surface offers or advertises a structured
    # SUD path. Free text stays free: what a clinician writes is never refused.
    class ReferralSurfacesTest < ActiveSupport::TestCase
      SUD_ROUTE_WORDS = /sud|substance|addiction|moud|opioid/i
      SUD_WORDS = /substance|SUD\b|addiction|MOUD|opioid|alcohol/i
      REFERRAL_CONTROLLERS = %w[service_requests pending_referrals].freeze

      # Records every call, so a refusal can prove nothing was registered.
      class RecordingGateway
        attr_reader :registered

        def initialize = @registered = []

        def register(attributes)
          @registered << attributes
          { success: true, ien: 9001 }
        end

        def for_patient(_dfn) = []
      end

      setup do
        @original_gateway = ServiceRequest.gateway
        @gateway = RecordingGateway.new
        ServiceRequest.gateway = @gateway
        @service = ReferralOriginationService.new
      end

      teardown do
        ServiceRequest.gateway = @original_gateway
      end

      # =========================================================================
      # THE DECLARED LIST
      # =========================================================================

      test "ROUTES is the frozen list of the engine's referral routes" do
        assert_predicate ReferralSurfaces::ROUTES, :frozen?
        assert_equal %w[pending_referrals#index service_requests#index service_requests#show],
                     ReferralSurfaces::ROUTES.sort
      end

      test "every engine route that serves referrals is declared in ROUTES" do
        undeclared = referral_routes.map { |route| endpoint(route) }.uniq - ReferralSurfaces::ROUTES

        assert_not_empty referral_routes, "the engine routes no referral surface at all: the guard is looking at nothing"
        assert_empty undeclared,
                     "referral routes not declared in ReferralSurfaces::ROUTES (declare them, and prove they " \
                     "offer no SUD path): #{undeclared.inspect}"
      end

      test "every entry in ROUTES resolves to a real engine route" do
        routed = engine_routes.map { |route| endpoint(route) }
        stale = ReferralSurfaces::ROUTES - routed

        assert_empty stale, "ReferralSurfaces::ROUTES names routes the engine does not have: #{stale.inspect}"
      end

      test "no engine route path names an SUD workflow" do
        named = engine_routes.map { |route| route.path.spec.to_s }.grep(SUD_ROUTE_WORDS)

        assert_empty named, "engine route paths that name an SUD path: #{named.inspect}"
      end

      # =========================================================================
      # STRUCTURED CODINGS
      # =========================================================================

      test "OFFERED_CODINGS is exactly the generic patient referral coding" do
        assert_predicate ReferralSurfaces::OFFERED_CODINGS, :frozen?
        assert_equal [ ServiceRequest::PATIENT_REFERRAL ], ReferralSurfaces::OFFERED_CODINGS
      end

      test "no offered coding names an SUD referral" do
        ReferralSurfaces::OFFERED_CODINGS.each do |coding|
          assert_no_match SUD_WORDS, coding.values.join(" ")
        end
      end

      test "an RCIS ServiceRequest emits only offered codings in code and category" do
        row = { ien: "501", referral_number: "TEST-0001", status: "A", purpose: "Counseling", facility: "TEST FACILITY",
                date: Date.new(2026, 1, 5) }
        fhir = ServiceRequest.from_rpms_row(row, patient_dfn: 100).to_fhir

        emitted = Array(fhir.dig(:code, :coding)) + Array(fhir[:category]).flat_map { |concept| Array(concept[:coding]) }

        assert_not_empty emitted
        assert_empty emitted - ReferralSurfaces::OFFERED_CODINGS,
                     "codings emitted outside ReferralSurfaces::OFFERED_CODINGS"
      end

      # =========================================================================
      # WHAT THE FHIR SURFACE ADVERTISES
      # =========================================================================

      test "the ServiceRequest search parameters document no SUD path" do
        params = FHIR::SearchCapabilities.search_params_for("ServiceRequest")

        assert_not_empty params
        params.each do |name, param|
          assert_no_match SUD_WORDS, name
          assert_no_match SUD_WORDS, param.documentation.to_s, "ServiceRequest search parameter #{name}"
        end
        assert_no_match SUD_WORDS, FHIR::SearchCapabilities.resource_capabilities("ServiceRequest").to_json
      end

      test "the CapabilityStatement ServiceRequest entry advertises no SUD path" do
        assert_no_match SUD_WORDS, FHIR::CapabilityStatement::RESOURCES.fetch("ServiceRequest").to_json

        statement = FHIR::CapabilityStatement.call(
          base_url: "https://ehr.test.example/fhir", token_endpoint: "https://ehr.test.example/oauth/token"
        )
        entries = statement[:rest].flat_map { |rest| rest[:resource] }.select { |r| r[:type] == "ServiceRequest" }

        entries.each { |entry| assert_no_match SUD_WORDS, entry.to_json }
      end

      # =========================================================================
      # ORIGINATION FAILS CLOSED ON ANYTHING STRUCTURED
      # =========================================================================

      test "ORIGINATION_FIELDS is frozen and is the three accepted keys" do
        assert_predicate ReferralSurfaces::ORIGINATION_FIELDS, :frozen?
        assert_equal %i[service_requested urgency reason_for_referral], ReferralSurfaces::ORIGINATION_FIELDS
      end

      test "origination refuses a Symbol referral_type key" do
        result = originate(accepted_params.merge(referral_type: "sud"))

        assert_refused result, "referral_type"
      end

      test "origination refuses a String category key" do
        result = originate(accepted_params.merge("category" => "substance-use"))

        assert_refused result, "category"
      end

      test "origination refuses an extra key on ActionController::Parameters" do
        params = ActionController::Parameters.new(
          accepted_params.merge(code: { system: "http://snomed.info/sct", code: "0000000" })
        )

        assert_refused originate(params), "code"
      end

      test "origination names every refused key" do
        result = originate(accepted_params.merge(referral_type: "sud", "category" => "substance-use"))

        assert_refused result, "referral_type"
        assert_match(/category/, result.errors.join(" "))
      end

      test "origination with only the accepted keys still succeeds" do
        result = originate(accepted_params)

        assert_predicate result, :success?
        assert_empty result.errors
        assert_equal "Counseling", result.service_request.service_requested
        assert_equal "ROUTINE", result.service_request.urgency
        assert_equal "Follow-up after screening", result.service_request.reason_for_referral
        assert_equal "draft", result.service_request.status
        assert_equal "100", result.patient_identifier
      end

      test "origination accepts the accepted keys as Strings and as ActionController::Parameters" do
        assert_predicate originate(accepted_params.stringify_keys.with_indifferent_access), :success?
        assert_predicate originate(ActionController::Parameters.new(accepted_params)), :success?
      end

      test "free text that mentions substance use is never refused" do
        result = originate(
          service_requested: "Counseling referral; client reports alcohol use",
          urgency: "ROUTINE",
          reason_for_referral: "Client asked about opioid and substance use support"
        )

        assert_predicate result, :success?, "free-text documentation must never be blocked: #{result.errors.inspect}"
        assert_equal "Counseling referral; client reports alcohol use", result.service_request.service_requested
        assert_equal "Client asked about opioid and substance use support", result.service_request.reason_for_referral
      end

      private

      def accepted_params
        { service_requested: "Counseling", urgency: "ROUTINE", reason_for_referral: "Follow-up after screening" }
      end

      def originate(params)
        @service.originate(patient_dfn: 100, provider_ien: 201, params: params)
      end

      def assert_refused(result, key)
        assert_not result.success?, "a params key outside ORIGINATION_FIELDS (#{key}) must be refused"
        assert_nil result.service_request
        errors = Array(result.errors).join(" ")
        assert_match(/#{key}/, errors)
        assert_match(/structured referral types? (is|are) not offered/i, errors)
        assert_empty @gateway.registered, "a refused origination must register nothing"
      end

      def engine_routes
        Lakeraven::EHR::Engine.routes.routes.to_a
      end

      def referral_routes
        engine_routes.select do |route|
          REFERRAL_CONTROLLERS.include?(controller_name(route)) ||
            route.path.spec.to_s.match?(/referral|ServiceRequest/)
        end
      end

      def controller_name(route)
        route.defaults[:controller].to_s.split("/").last
      end

      def endpoint(route)
        "#{controller_name(route)}##{route.defaults[:action]}"
      end
    end
  end
end
