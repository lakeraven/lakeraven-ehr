# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # Pins the CapabilityStatement source of truth for #574 / #647: each IHS
    # capability names the FHIR interactions it owns; Patient read/search stay
    # available without any IHS capability (registration only gates create).
    class FeatureAvailabilityTest < ActiveSupport::TestCase
      include IhsFeatureAvailabilityTestHelper

      teardown { teardown_restricted_backend }

      PINNED_CAPABILITY_FHIR_INTERACTIONS = {
        prc_referrals: [
          %w[ServiceRequest search-type]
        ],
        tribal_enrollment: [],
        bprm_registration: [
          %w[Patient create]
        ],
        bprm_scheduling: [],
        ihs_immunization: [
          %w[Immunization search-type]
        ],
        pcc_screens: []
      }.freeze

      test "each registered capability maps to the FHIR interactions it owns" do
        assert_equal PINNED_CAPABILITY_FHIR_INTERACTIONS,
                     BackendRegistry.capability_fhir_interactions
      end

      # The engine routes ServiceRequest and Immunization as index only, so the
      # map must not advertise a read it does not serve (Copilot round, #659).
      test "ServiceRequest and Immunization advertise search-type only, because they have no show route" do
        %w[ServiceRequest Immunization].each do |type|
          assert_equal [ "search-type" ], BackendRegistry.supported_fhir_interactions(type), type
        end
      end

      # Walks everything actually advertised (capability-owned and base), and
      # fails if it finds no read at all, so it cannot pass by iterating nothing.
      test "every advertised read interaction has a show route" do
        shows = Lakeraven::EHR::Engine.routes.routes.select { |r| r.defaults[:action] == "show" }
          .map { |r| r.defaults[:controller] }
        reads = BackendRegistry.supported_fhir_resource_types.select do |type|
          BackendRegistry.supported_fhir_interactions(type).include?("read")
        end
        refute_empty reads, "expected at least one advertised read (Patient) so this check can fail"
        reads.each do |type|
          controller = "lakeraven/ehr/#{type.underscore.pluralize}"
          assert_includes shows, controller, "#{type} is advertised as readable but has no show route"
        end
      end

      test "supported_fhir_resource_types on rpms lists every IHS-owned type plus Patient" do
        expected = %w[Immunization Patient ServiceRequest]
        assert_equal expected.sort, BackendRegistry.supported_fhir_resource_types.sort
      end

      test "supported_fhir_resource_types always includes Patient even without IHS capabilities" do
        with_restricted_backend(capabilities: []) do
          types = BackendRegistry.supported_fhir_resource_types
          assert_includes types, "Patient"
          refute_includes types, "Immunization"
          refute_includes types, "ServiceRequest"
        end
      end

      test "supported_fhir_resource_types reflects a partial capability set" do
        with_restricted_backend(capabilities: [ :ihs_immunization ]) do
          assert_equal %w[Immunization Patient].sort,
                       BackendRegistry.supported_fhir_resource_types.sort
        end
      end

      test "supported_fhir_interactions exposes Patient read and search without bprm_registration" do
        with_restricted_backend(capabilities: []) do
          assert_includes BackendRegistry.supported_fhir_interactions("Patient"), "read"
          assert_includes BackendRegistry.supported_fhir_interactions("Patient"), "search-type"
          refute_includes BackendRegistry.supported_fhir_interactions("Patient"), "create"
        end
      end

      test "supported_fhir_interactions adds Patient create when bprm_registration is provided" do
        with_restricted_backend(capabilities: [ :bprm_registration ]) do
          interactions = BackendRegistry.supported_fhir_interactions("Patient")
          assert_includes interactions, "read"
          assert_includes interactions, "create"
        end
      end

      # SPEC #669: capability-gated interactions must match routes in both directions.
      REGISTRY_GATED_RESOURCE_TYPES = BackendRegistry::CAPABILITY_FHIR_INTERACTIONS.values.flatten(1)
        .map(&:first).uniq.freeze

      FHIR_ACTION_INTERACTIONS = {
        "index" => "search-type",
        "show" => "read",
        "create" => "create"
      }.freeze

      test "each capability-gated FHIR interaction has the route kind it needs" do
        routed = fhir_routes_by_type

        BackendRegistry::CAPABILITY_FHIR_INTERACTIONS.each_value do |pairs|
          pairs.each do |type, interaction|
            routes = routed.fetch(type)
            case interaction
            when "search-type"
              assert_includes routes, :index, "#{type} search-type needs a GET index route"
            when "create"
              assert_includes routes, :create, "#{type} create needs a POST create route"
            when "read"
              assert_includes routes, :show, "#{type} read needs a GET show route"
            else
              flunk "unexpected gated interaction #{type} #{interaction}"
            end
          end
        end
      end

      test "each routed action on a registry-gated resource type maps to a supported interaction" do
        routed = fhir_routes_by_type

        REGISTRY_GATED_RESOURCE_TYPES.each do |type|
          routed.fetch(type).each do |route_kind|
            next unless FHIR_ACTION_INTERACTIONS.key?(route_kind.to_s)

            interaction = FHIR_ACTION_INTERACTIONS.fetch(route_kind.to_s)
            supported = BackendRegistry.supported_fhir_interactions(type)
            assert_includes supported, interaction,
                            "#{type} route #{route_kind} implies #{interaction}, " \
                            "which must be listed in BASE or a provided capability"
          end
        end
      end

      private

      def fhir_routes_by_type
        Lakeraven::EHR::Engine.routes.routes.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |route, types|
          segments = route.path.spec.to_s.delete_suffix("(.:format)").split("/").reject(&:empty?)
          type = segments.first
          next unless type&.match?(/\A[A-Z][A-Za-z]+\z/)

          kind = route_kind(route.verb, segments.drop(1))
          types[type] << kind if kind
        end.transform_values(&:uniq)
      end

      def route_kind(verb, rest)
        return :show if verb == "GET" && rest.length == 1
        return :index if verb == "GET" && rest.empty?

        :create if verb == "POST" && rest.empty?
      end
    end
  end
end
