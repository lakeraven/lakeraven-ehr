# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # #905 (slice of #522): the December build is MH/BH only and must not hold
    # itself out as providing SUD referral for treatment (42 CFR 2.11). The
    # control is that no referral surface offers or advertises a structured
    # SUD path. Free text stays free: what a clinician writes is never refused.
    class ReferralSurfacesTest < ActiveSupport::TestCase
      include IhsFeatureAvailabilityTestHelper

      SUD_WORDS = /substance|\bSUDs?\b|sud_|addiction|MOUD|\bMAT\b|opioid|alcohol|detox|methadone|buprenorphine|
                   naloxone|chemical\ dependency/ix
      # A route path is split into segments so "format" is not read as MAT.
      SUD_ROUTE_SEGMENT = /\A(sud|suds|substance|addiction|moud|mat|opioid|detox)\z/i
      SUD_ROUTE_SUBSTRING = /substance|addiction|opioid/i
      ROUTE_SEGMENT_BREAK = %r{[/.()\-_:]}

      # What makes a route a referral surface: what its controller touches, or
      # what its path says. Never the controller's name alone.
      REFERRAL_SOURCE = /ServiceRequest|ServiceRequestGateway|ReferralOriginationService|referral/i
      REFERRAL_PATH = /referral|servicerequest/i

      # The declared surfaces that render HTML, and so can offer a form control.
      HTML_SURFACES = %w[dashboards pending_referrals].freeze
      LAYOUT = "app/views/layouts/lakeraven/ehr/application.html.erb"
      STRUCTURED_CONTROL_NAMES = "referral_type|category|code|program|specialty"
      # A control so named, written as HTML or through a Rails form helper.
      STRUCTURED_CONTROL = /
        <(select|input|option)\b[^>]*\bname=["'][^"']*\b(#{STRUCTURED_CONTROL_NAMES})\b |
        \b\w*(field|select|check_box|radio_button|text_area|options)\w*[\s(]+:?["']?(\w+\[)?(#{STRUCTURED_CONTROL_NAMES})\b
      /ix

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
        teardown_restricted_backend
      end

      # =========================================================================
      # THE DECLARED LIST
      # =========================================================================

      test "ROUTES is the frozen list of the engine's referral routes" do
        assert_predicate ReferralSurfaces::ROUTES, :frozen?
        assert_equal %w[dashboards#show pending_referrals#index service_requests#index service_requests#show],
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

      test "the dashboard is selected as a referral surface by what its controller reads" do
        selected = referral_routes.map { |route| endpoint(route) }

        assert_includes selected, "dashboards#show"
        assert_includes selected, "pending_referrals#index"
        assert_includes selected, "service_requests#index"
      end

      test "every route to a declared referral surface is read-only" do
        declared = engine_routes.select { |route| ReferralSurfaces::ROUTES.include?(endpoint(route)) }
        writes = declared.reject { |route| route.verb == "GET" }.map { |route| "#{route.verb} #{route.path.spec}" }

        assert_not_empty declared
        assert_empty writes, "a declared referral surface takes a write verb: #{writes.inspect}"
      end

      test "no engine route path names an SUD workflow" do
        paths = engine_routes.map { |route| route.path.spec.to_s }
        named = paths.select { |path| sud_route_path?(path) }

        assert_not_empty paths
        assert_empty named, "engine route paths that name an SUD path: #{named.inspect}"
      end

      test "the route path check reads whole segments" do
        assert sud_route_path?("/referrals/sud(.:format)")
        assert sud_route_path?("/patients/:dfn/mat-referral(.:format)")
        assert sud_route_path?("/SubstanceUseReferral(.:format)")
        assert_not sud_route_path?("/referrals/pending(.:format)")
        assert_not sud_route_path?("/Measure/$import(.:format)")
      end

      # =========================================================================
      # WHAT THE DECLARED SURFACES RENDER
      # =========================================================================

      test "every declared surface with templates is inspected as an HTML surface" do
        with_views = declared_controllers.select { |name| templates_for(name).any? }

        assert_empty with_views - HTML_SURFACES,
                     "declared referral surfaces render templates this guard does not inspect: #{with_views.inspect}"
      end

      test "the declared surfaces' controllers, templates and layout name no SUD path" do
        controllers = (declared_controllers | HTML_SURFACES).map { |name| controller_source(name) }
        templates = HTML_SURFACES.flat_map { |name| templates_for(name) }

        assert_not_empty controllers
        HTML_SURFACES.each { |name| assert_not_empty templates_for(name), "no templates found for #{name}" }
        (controllers + templates + [ engine_file(LAYOUT) ]).each do |file|
          assert_predicate file, :file?, "#{file} is missing: the guard is looking at nothing"
          assert_no_match SUD_WORDS, file.read, "#{file.relative_path_from(Engine.root)} names an SUD path"
        end
      end

      test "the pending-referrals and dashboard templates offer no structured referral control" do
        templates = HTML_SURFACES.flat_map { |name| templates_for(name) }

        assert_not_empty templates
        templates.each do |file|
          assert_no_match STRUCTURED_CONTROL, file.read,
                          "#{file.relative_path_from(Engine.root)} offers a structured referral control"
        end
      end

      test "the structured control check sees HTML and form helpers" do
        assert_match STRUCTURED_CONTROL, %(<select name="referral_type">)
        assert_match STRUCTURED_CONTROL, %(<input type="radio" name="referral[category]">)
        assert_match STRUCTURED_CONTROL, %(<%= select_tag :program, options %>)
        assert_match STRUCTURED_CONTROL, %(<%= form.text_field "specialty" %>)
        assert_no_match STRUCTURED_CONTROL, %(<%= date_field_tag :from, @from %>)
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

        register_restricted_backend(capabilities: [ :prc_referrals ])
        assert BackendRegistry.current.provides?(:prc_referrals)
        statement = FHIR::CapabilityStatement.call(
          base_url: "https://ehr.test.example/fhir", token_endpoint: "https://ehr.test.example/oauth/token"
        )
        entries = statement[:rest].flat_map { |rest| rest[:resource] }.select { |r| r[:type] == "ServiceRequest" }

        assert_not_empty entries, "a backend that provides :prc_referrals must advertise ServiceRequest"
        entries.each do |entry|
          assert_not_empty Array(entry[:searchParam]), "the rendered ServiceRequest entry lists no search parameter"
          assert_no_match SUD_WORDS, entry.to_json
        end
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

      test "origination refuses a Hash under an accepted key" do
        result = originate(accepted_params.merge(service_requested: { system: "http://snomed.info/sct", code: "0000000" }))

        assert_refused result, "service_requested"
      end

      test "origination refuses ActionController::Parameters under an accepted key" do
        coding = ActionController::Parameters.new(system: "http://snomed.info/sct", code: "0000000")

        assert_refused originate(accepted_params.merge(service_requested: coding)), "service_requested"
        assert_refused originate(ActionController::Parameters.new(accepted_params.merge(service_requested: coding.to_unsafe_h))),
                       "service_requested"
      end

      test "origination refuses an Array under an accepted key" do
        result = originate(accepted_params.merge(reason_for_referral: %w[a b]))

        assert_refused result, "reason_for_referral"
      end

      test "origination refuses params that are a String, without raising" do
        assert_refused_shape originate("Counseling")
      end

      test "origination refuses params that are an Array of pairs, without raising" do
        assert_refused_shape originate([ [ :service_requested, "Counseling" ], [ :urgency, "ROUTINE" ] ])
      end

      test "origination refuses a key given both as Symbol and String as ambiguous" do
        result = originate(accepted_params.merge(service_requested: "A", "service_requested" => "B"))

        assert_refused_shape result
        assert_match(/service_requested/, result.errors.join(" "))
        assert_match(/ambiguous/i, result.errors.join(" "))
      end

      test "a refused key that does not look like a field name is counted, never echoed" do
        result = originate(accepted_params.merge("DOE,TEST 000-00-0000" => "x"))
        errors = Array(result.errors).join(" ")

        assert_refused_shape result
        assert_match(/structured referral types? (is|are) not offered/i, errors)
        assert_no_match(/DOE/, errors)
        assert_no_match(/000-00-0000/, errors)
        assert_match(/1 other/, errors)
      end

      test "a refused key that looks like a field name is echoed beside the count of the others" do
        result = originate(accepted_params.merge(referral_type: "sud", "DOE,TEST 000-00-0000" => "x"))
        errors = Array(result.errors).join(" ")

        assert_refused result, "referral_type"
        assert_no_match(/DOE/, errors)
        assert_match(/1 other/, errors)
      end

      test "the refusal says which keys origination accepts" do
        errors = Array(originate(accepted_params.merge(referral_type: "sud")).errors).join(" ")

        ReferralSurfaces::ORIGINATION_FIELDS.each { |field| assert_match(/#{field}/, errors) }
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
        assert_refused_shape result, "#{key} must be refused"
        errors = Array(result.errors).join(" ")
        assert_match(/#{key}/, errors)
        assert_match(/structured referral types? (is|are) not offered/i, errors)
      end

      def assert_refused_shape(result, message = "origination must be refused")
        assert_kind_of ReferralOriginationService::OriginationResult, result
        assert_not result.success?, message
        assert_nil result.service_request
        assert_not_empty Array(result.errors)
        assert_empty @gateway.registered, "a refused origination must register nothing"
      end

      def engine_routes
        Lakeraven::EHR::Engine.routes.routes.to_a
      end

      def referral_routes
        engine_routes.select do |route|
          controller_reads_referrals?(route.defaults[:controller]) || route.path.spec.to_s.match?(REFERRAL_PATH)
        end
      end

      def controller_reads_referrals?(controller)
        return false if controller.blank?

        source = engine_file("app/controllers/#{controller}_controller.rb")
        source.file? && source.read.match?(REFERRAL_SOURCE)
      end

      def sud_route_path?(path)
        path.match?(SUD_ROUTE_SUBSTRING) || path.split(ROUTE_SEGMENT_BREAK).any? { |part| part.match?(SUD_ROUTE_SEGMENT) }
      end

      def declared_controllers
        ReferralSurfaces::ROUTES.map { |entry| entry.split("#").first }.uniq
      end

      def controller_source(name)
        engine_file("app/controllers/lakeraven/ehr/#{name}_controller.rb")
      end

      def templates_for(name)
        Engine.root.glob("app/views/lakeraven/ehr/#{name}/**/*").select(&:file?)
      end

      def engine_file(path)
        Engine.root.join(path)
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
