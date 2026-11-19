# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/sud_words"

module Lakeraven
  module EHR
    # #905 (slice of #522): the December build is MH/BH only and must not hold
    # itself out as providing SUD referral for treatment (42 CFR 2.11). The
    # control is that no referral surface offers or advertises a structured
    # SUD path. Free text stays free: what a clinician writes is never refused.
    class ReferralSurfacesTest < ActiveSupport::TestCase
      include IhsFeatureAvailabilityTestHelper

      SUD_WORDS = SudWords::SUD_WORDS
      ROUTE_SEGMENT_BREAK = %r{[/.()\-_:$]}

      # What makes a route a referral surface: what its controller touches, or
      # what its path says. Never the controller's name alone.
      REFERRAL_SOURCE = /ServiceRequest|service_requests|ServiceRequestGateway|ReferralOriginationService|referral/i
      REFERRAL_PATH = /referral|servicerequest/i

      DECLARED_ROUTES = %w[
        lakeraven/ehr/dashboards#show lakeraven/ehr/pending_referrals#index
        lakeraven/ehr/service_requests#index lakeraven/ehr/service_requests#show
      ].freeze

      # The declared surfaces that render HTML. What they render is checked on
      # the rendered page: test/integration/referral_surfaces_rendered_test.rb.
      HTML_SURFACES = %w[lakeraven/ehr/dashboards lakeraven/ehr/pending_referrals].freeze
      LAYOUT = "app/views/layouts/lakeraven/ehr/application.html.erb"
      COMPONENTS_HELPER = "app/helpers/lakeraven/ehr/components_helper.rb"
      HELPERS = "app/helpers/lakeraven/ehr/*.rb"
      RouteLike = Struct.new(:path, :defaults, :name, :verb)
      PathLike = Struct.new(:spec)

      ERB_COMMENT = /<%#.*?%>/m
      LITERAL_RENDER = /\brender[\s(]+(?:partial:\s*)?["']([^"']+)["']/
      ANY_RENDER = /\brender\b(?![\w:])/

      setup do
        @service = ReferralOriginationService.new
      end

      teardown do
        teardown_restricted_backend
      end

      # =========================================================================
      # THE DECLARED LIST
      # =========================================================================

      test "ROUTES is the frozen list of the engine's referral routes, by full controller path" do
        assert_predicate ReferralSurfaces::ROUTES, :frozen?
        assert_equal DECLARED_ROUTES, ReferralSurfaces::ROUTES.sort
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

        assert_includes selected, "lakeraven/ehr/dashboards#show"
        assert_includes selected, "lakeraven/ehr/pending_referrals#index"
        assert_includes selected, "lakeraven/ehr/service_requests#index"
      end

      test "a same-named controller in another namespace is not a declared surface" do
        assert declared?(route_like("/referrals/pending(.:format)", "lakeraven/ehr/pending_referrals", "index")),
               "the comparison declares nothing: the guard is looking at nothing"
        assert_not declared?(route_like("/other/referrals/pending(.:format)", "lakeraven/ehr/other/pending_referrals", "index"))
        assert_not declared?(route_like("/referrals/pending(.:format)", "pending_referrals", "index"))
        assert_not declared?(route_like("/referrals/pending(.:format)", "lakeraven/ehr/pending_referrals", "create"))
      end

      test "every route to a declared referral surface is read-only" do
        declared = engine_routes.select { |route| declared?(route) }
        writes = declared.reject { |route| route.verb == "GET" }.map { |route| "#{route.verb} #{route.path.spec}" }

        assert_not_empty declared
        assert_empty writes, "a declared referral surface takes a write verb: #{writes.inspect}"
      end

      test "no engine route names an SUD workflow in its path, controller, action or name" do
        named = engine_routes.filter_map do |route|
          hits = route_sud_hits(route)
          "#{route.name} #{route.path.spec} #{endpoint(route)}: #{hits.join(', ')}" if hits.any?
        end

        assert_not_empty engine_routes
        assert_empty named, "engine routes that name an SUD path: #{named.inspect}"
      end

      test "the route check reads the controller, the action and the route name, not only the path" do
        clean = route_like("/referrals/pending(.:format)", "lakeraven/ehr/pending_referrals", "index", "pending_referrals")

        assert_empty route_sud_hits(clean)
        assert_not_empty route_sud_hits(route_like("/referrals/kind/:id", "lakeraven/ehr/sud_referrals", "index"))
        assert_not_empty route_sud_hits(route_like("/referrals/kind/:id", "lakeraven/ehr/referrals", "refer_to_mat"))
        assert_not_empty route_sud_hits(route_like("/referrals/kind/:id", "lakeraven/ehr/referrals", "index", "sudreferral"))
        assert_not_empty route_sud_hits(route_like("/referrals/oud-program", "lakeraven/ehr/referrals", "index"))
      end

      test "the route path check reads the words of a path" do
        %w[
          /referrals/sud(.:format) /patients/:dfn/mat-referral(.:format) /SubstanceUseReferral(.:format)
          /SudReferral(.:format) /referrals/sud_program(.:format) /drug-referrals /referrals/rehab
          /recovery_referrals /SBIRT/$refer /aod/referrals /withdrawal-management /ChemicalDependency(.:format)
          /sudreferral /matreferral(.:format) /referrals/oud /aud-treatment /referrals/asam/:level /sober-living
        ].each { |path| assert_not_empty sud_route_hits(path), "#{path} names an SUD path" }

        %w[/referrals/pending(.:format) /Measure/$import(.:format) /patients/:dfn/formats /sudo/audit].each do |path|
          assert_empty sud_route_hits(path), "#{path} names no SUD path"
        end
      end

      test "the SUD word check reads CamelCase and snake_case names" do
        [
          "SudReferral", "sud_program", "SUDs", "class SUDReferralForm", "mat_referral", "AodProgram",
          "withdrawal_management", "WithdrawalManagement", "chemical-dependency", "chemical_dependency",
          "drug court", "rehabilitation", "recovery support", "SBIRT", "suboxone", "narcotic",
          "OUD", "AUD", "opiate", "ASAM", "naltrexone", "Vivitrol", "heroin", "fentanyl", "sober", "sobriety",
          "opioid use disorder", "AlcoholUseDisorder", "use_disorder", "addict", "addicted", "chemical dependence",
          "ChemicalDependence", "intoxication", "sudreferral", "matreferral", "SUDREFERRAL", "sudprogram",
          "oudtreatment", "sudintake", "sud-referral", "MAT referral", "OudProgram"
        ].each { |text| assert_not_empty sud_hits(text), "#{text} names an SUD path" }

        [
          "format", "pseudonym", "sudo", "material", "ServiceRequest", "pending_referrals", "audit", "audience",
          "loud", "cloud program", "formatreferral", "matter", "automatic", "disorder", "use", "depend"
        ].each do |text|
          assert_empty sud_hits(text), "#{text} names no SUD path"
        end
      end

      # =========================================================================
      # WHAT THE DECLARED SURFACES RENDER
      # =========================================================================

      test "every declared surface with templates is inspected as an HTML surface" do
        with_views = declared_controllers.select { |name| templates_for(name).any? }

        assert_empty with_views - HTML_SURFACES,
                     "declared referral surfaces render templates this guard does not inspect: #{with_views.inspect}"
      end

      test "the declared surfaces' controllers, templates, partials, layout and helpers name no SUD path" do
        controllers = (declared_controllers | HTML_SURFACES).map { |name| controller_source(name) }
        rendered = HTML_SURFACES.flat_map { |name| rendered_files(name) }.uniq
        layout = with_partials([ engine_file(LAYOUT) ])
        helpers = Engine.root.glob(HELPERS)

        assert_not_empty controllers
        assert_operator layout.size, :>, 1, "the layout's own partials were not found"
        assert_includes helpers, engine_file(COMPONENTS_HELPER)
        HTML_SURFACES.each { |name| assert_not_empty templates_for(name), "no templates found for #{name}" }
        (controllers + rendered + layout + helpers).uniq.each do |file|
          assert_predicate file, :file?, "#{file} is missing: the guard is looking at nothing"
          assert_empty sud_hits(file.read), "#{relative(file)} names an SUD path"
        end
      end

      test "the shared partials a declared surface renders are read too" do
        pending = rendered_files("lakeraven/ehr/pending_referrals").map { |file| relative(file) }
        dashboard = rendered_files("lakeraven/ehr/dashboards").map { |file| relative(file) }

        assert_includes pending, "app/views/lakeraven/ehr/pending_referrals/index.html.erb"
        assert_includes pending, "app/views/lakeraven/ehr/shared/_form_field.html.erb"
        assert_includes pending, "app/views/lakeraven/ehr/shared/_status_badge.html.erb"
        assert_includes dashboard, "app/views/lakeraven/ehr/dashboards/_pending_referrals.html.erb"
        assert_includes dashboard, "app/views/lakeraven/ehr/shared/_alert.html.erb"
      end

      test "a component helper that renders inputs leads to its partials" do
        assert_equal [ "form_field" ], component_partials.fetch("form_field")
        assert_equal %w[choice_list lookup_chosen lookup_search], component_partials.fetch("lookup_field").sort
        assert_includes partials_rendered_by(%(<%= lookup_field f, :program, legend: "Program" %>), "x/y"),
                        engine_file("app/views/lakeraven/ehr/shared/_choice_list.html.erb")
        assert_includes partials_rendered_by(%(<%= render "lakeraven/ehr/shared/patient_search_form", query: @q %>), "x/y"),
                        engine_file("app/views/lakeraven/ehr/shared/_patient_search_form.html.erb")
        assert_includes partials_rendered_by(%(<%= render partial: "kinds", locals: {} %>), "lakeraven/ehr/dashboards"),
                        engine_file("app/views/lakeraven/ehr/dashboards/_kinds.html.erb")
      end

      test "every render in a declared surface names its partial, so the guard can read it" do
        HTML_SURFACES.flat_map { |name| rendered_files(name) }.uniq.each do |file|
          assert_predicate file, :file?, "#{relative(file)} is rendered by a declared surface but is missing"
          source = file.read.gsub(ERB_COMMENT, "")

          assert_equal source.scan(ANY_RENDER).size, source.scan(LITERAL_RENDER).size,
                       "#{relative(file)} renders something this guard cannot resolve to a file"
        end
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
          assert_empty sud_hits(coding.values.join(" "))
        end
      end

      test "every coding an RCIS ServiceRequest emits, anywhere in its FHIR, is an offered coding" do
        row = { ien: "501", referral_number: "TEST-0001", status: "A", purpose: "Counseling", facility: "TEST FACILITY",
                date: Date.new(2026, 1, 5) }
        emitted = codings_in(ServiceRequest.from_rpms_row(row, patient_dfn: 100).to_fhir)

        assert_not_empty emitted
        assert_empty emitted - ReferralSurfaces::OFFERED_CODINGS,
                     "codings emitted outside ReferralSurfaces::OFFERED_CODINGS"
      end

      test "the coding walk finds a coding at any depth" do
        nested = { code: { coding: [ { code: "a" } ] }, "orderDetail" => [ { "coding" => { code: "b" } } ],
                   extension: [ { valueCodeableConcept: { coding: [ { code: "c" } ] } } ] }

        assert_equal %w[a b c], codings_in(nested).map { |coding| coding[:code] }
      end

      # =========================================================================
      # WHAT THE FHIR SURFACE ADVERTISES
      # =========================================================================

      test "the ServiceRequest search parameters document no SUD path" do
        params = FHIR::SearchCapabilities.search_params_for("ServiceRequest")

        assert_not_empty params
        params.each do |name, param|
          assert_empty sud_hits(name.to_s)
          assert_empty sud_hits(param.documentation.to_s), "ServiceRequest search parameter #{name}"
        end
        assert_empty sud_hits(FHIR::SearchCapabilities.resource_capabilities("ServiceRequest").to_json)
      end

      test "the CapabilityStatement ServiceRequest entry advertises no SUD path" do
        assert_empty sud_hits(FHIR::CapabilityStatement::RESOURCES.fetch("ServiceRequest").to_json)

        register_restricted_backend(capabilities: [ :prc_referrals ])
        assert BackendRegistry.current.provides?(:prc_referrals)
        statement = FHIR::CapabilityStatement.call(
          base_url: "https://ehr.test.example/fhir", token_endpoint: "https://ehr.test.example/oauth/token"
        )
        entries = statement[:rest].flat_map { |rest| rest[:resource] }.select { |r| r[:type] == "ServiceRequest" }

        assert_not_empty entries, "a backend that provides :prc_referrals must advertise ServiceRequest"
        entries.each do |entry|
          assert_not_empty Array(entry[:searchParam]), "the rendered ServiceRequest entry lists no search parameter"
          assert_empty sud_hits(entry.to_json)
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

        assert_refused_uncounted result, 1
      end

      test "origination refuses an extra key on ActionController::Parameters" do
        params = ActionController::Parameters.new(
          accepted_params.merge(code: { system: "http://snomed.info/sct", code: "0000000" })
        )

        assert_refused_uncounted originate(params), 1
      end

      test "origination names every refused key that is a ServiceRequest attribute" do
        result = originate(accepted_params.merge(referral_type: "sud", "diagnosis_codes" => "F00.0"))

        assert_includes ServiceRequest.attribute_names, "referral_type"
        assert_includes ServiceRequest.attribute_names, "diagnosis_codes"
        assert_refused result, "referral_type"
        assert_match(/diagnosis_codes/, result.errors.join(" "))
        assert_no_match(/other/, result.errors.join(" "))
      end

      test "a refused key that is not a ServiceRequest attribute is counted, never echoed" do
        unsafe = [ "TESTPATIENT", "A000123", "DOE,TEST 000-00-0000" ]
        result = originate(accepted_params.merge(unsafe.index_with { "x" }))
        errors = Array(result.errors).join(" ")

        assert_refused_shape result
        assert_match(/structured referral types? (is|are) not offered/i, errors)
        unsafe.each { |key| assert_no_match(/#{Regexp.escape(key)}/, errors) }
        assert_no_match(/TESTPATIENT|A000123|DOE|000-00-0000/, errors)
        assert_match(/3 other/, errors)
      end

      test "attribute names are echoed beside the count of every other refused key" do
        result = originate(accepted_params.merge(referral_type: "sud", "category" => "x", "TESTPATIENT" => "x", A000123: "x"))
        errors = Array(result.errors).join(" ")

        assert_refused result, "referral_type"
        assert_no_match(/category|TESTPATIENT|A000123/, errors)
        assert_match(/3 other/, errors)
      end

      test "origination reads values only for keys that are present" do
        coded = Hash.new { |_hash, _key| { system: "http://snomed.info/sct", code: "0000000" } }.merge!(urgency: "ROUTINE")
        defaulted = Hash.new("Counseling").merge!(urgency: "ROUTINE")

        [ coded, defaulted ].each do |params|
          result = originate(params)
          errors = Array(result.errors).join(" ")

          assert_kind_of ReferralOriginationService::OriginationResult, result
          assert_not result.success?, "a value no key holds must not originate a referral"
          assert_match(/service requested/i, errors)
          assert_no_match(/snomed|0000000|Counseling/, errors)
          assert_no_match(/snomed|0000000|Counseling/, result.service_request&.service_requested.to_s)
        end
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

      test "origination says params that are not a Hash are not a set of named fields" do
        errors = Array(originate("Counseling").errors).join(" ")

        assert_match(/not a set of named fields/, errors)
        assert_no_match(/other key/, errors, "the reason must not be hidden behind a count of keys")
        assert_no_match(/Counseling/, errors, "what was sent is never echoed")
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

      # Refused for a key that is not echoed: counted among the others.
      def assert_refused_uncounted(result, count)
        assert_refused_shape result
        errors = Array(result.errors).join(" ")
        assert_match(/structured referral types? (is|are) not offered/i, errors)
        assert_match(/#{count} other/, errors)
      end

      def assert_refused_shape(result, message = "origination must be refused")
        assert_kind_of ReferralOriginationService::OriginationResult, result
        assert_not result.success?, message
        assert_nil result.service_request
        assert_not_empty Array(result.errors)
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

      def sud_hits(text)
        SudWords.hits(text)
      end

      def sud_route_hits(path)
        sud_hits(path.to_s.split(ROUTE_SEGMENT_BREAK).join(" "))
      end

      # The SUD words in a route's path, controller, action or name.
      def route_sud_hits(route)
        [ route.path.spec, route.defaults[:controller], route.defaults[:action], route.name ].flat_map do |part|
          sud_route_hits(part)
        end.uniq
      end

      # Whether a route is a declared referral surface: by its full
      # controller path and action, never by the controller's name alone.
      def declared?(route)
        ReferralSurfaces::ROUTES.include?(endpoint(route))
      end

      # A surface's templates and, transitively, every partial they render by
      # name or through a ComponentsHelper helper.
      def rendered_files(name)
        with_partials(templates_for(name))
      end

      def with_partials(files)
        files = files.dup
        files.each do |file|
          next unless file.file?

          partials_rendered_by(file.read, file.dirname.relative_path_from(engine_file("app/views")).to_s).each do |partial|
            files << partial unless files.include?(partial)
          end
        end
        files
      end

      def partials_rendered_by(source, directory)
        source = source.gsub(ERB_COMMENT, "")
        named = source.scan(LITERAL_RENDER).flatten.map { |partial| partial.include?("/") ? partial : "#{directory}/#{partial}" }
        components = component_partials.select { |helper, _| source.match?(/(?<![\w#])#{helper}(?!\w)/) }.values.flatten
        (named + components.map { |partial| "#{ComponentsHelper::SHARED}/#{partial}" }).uniq.map do |partial|
          engine_file("app/views/#{File.dirname(partial)}/_#{File.basename(partial)}.html.erb")
        end
      end

      # ComponentsHelper helper name => the shared partials it renders,
      # including those of the helpers it calls.
      def component_partials
        @component_partials ||= begin
          bodies = engine_file(COMPONENTS_HELPER).read.split(/^\s*def /).drop(1).to_h { |body| [ body[/\A\w+/], body ] }
          direct = bodies.transform_values { |body| body.scan(%r{\#\{SHARED\}/(\w+)}).flatten }
          bodies.to_h do |helper, body|
            called = bodies.keys.select { |other| other != helper && body.match?(/(?<![\w.])#{other}(?!\w)/) }
            [ helper, (direct[helper] + called.flat_map { |other| direct[other] }).uniq ]
          end
        end
      end

      # A stand-in for a route: what the declared comparison and the SUD
      # route check read of one.
      def route_like(path, controller, action, name = nil)
        RouteLike.new(PathLike.new(path), { controller: controller, action: action }, name, "GET")
      end

      def codings_in(node)
        case node
        when Hash then node.flat_map { |key, value| (key.to_s == "coding" ? Array.wrap(value) : []) + codings_in(value) }
        when Array then node.flat_map { |value| codings_in(value) }
        else []
        end
      end

      def declared_controllers
        ReferralSurfaces::ROUTES.map { |entry| entry.split("#").first }.uniq
      end

      def controller_source(name)
        engine_file("app/controllers/#{name}_controller.rb")
      end

      def templates_for(name)
        Engine.root.glob("app/views/#{name}/**/*").select(&:file?)
      end

      def engine_file(path)
        Engine.root.join(path)
      end

      def relative(file)
        file.relative_path_from(Engine.root).to_s
      end

      def endpoint(route)
        "#{route.defaults[:controller]}##{route.defaults[:action]}"
      end
    end
  end
end
