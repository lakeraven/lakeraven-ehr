# frozen_string_literal: true

require "test_helper"

# SPEC #669: /metadata must advertise only interactions the current backend
# serves (BASE plus capabilities from BackendRegistry.current.provides?).
module Lakeraven
  module EHR
    class CapabilityStatementBackendAvailabilityTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper
      include IhsFeatureAvailabilityTestHelper

      ENGINE = "/lakeraven-ehr"
      METADATA = "#{ENGINE}/metadata".freeze
      SMART_CONFIGURATION = "#{ENGINE}/.well-known/smart-configuration".freeze
      READ_SCOPE_WILDCARD = "system/*.rs".freeze
      INTERACTION_TO_SCOPE_PERMISSION = { "create" => "c", "read" => "r", "search-type" => "s" }.freeze
      INTERACTIONS_FOR_SCOPE_ORDER = %w[create read search-type].freeze

      CAPABILITY_SUBSETS = (
        [ [] ] +
        [ BackendRegistry::CAPABILITIES ] +
        BackendRegistry::CAPABILITIES.map { |capability| [ capability ] }
      ).freeze

      REGISTRY_GATED_TYPES = BackendRegistry::CAPABILITY_FHIR_INTERACTIONS.values.flatten(1)
        .map(&:first).uniq.freeze

      PINNED_DEFAULT_INTERACTIONS = {
        "Patient" => %w[create read search-type],
        "Practitioner" => %w[read search-type],
        "ServiceRequest" => %w[search-type],
        "Immunization" => %w[search-type]
      }.freeze

      setup do
        setup_smart_auth(scopes: "system/*.* system/Patient.write")
        @fhir_headers = @headers.merge("Accept" => "application/fhir+json")
      end

      teardown do
        teardown_smart_auth
        teardown_restricted_backend
      end

      test "default backend metadata still pins key interactions unchanged" do
        load_metadata_interactions!

        PINNED_DEFAULT_INTERACTIONS.each do |type, expected|
          assert_equal expected.sort, @metadata_interactions.fetch(type).sort,
                       "#{type} interactions on rpms backend"
        end
      end

      test "restricted backend metadata drops gated interactions and empty resource types" do
        with_restricted_backend(capabilities: []) do
          load_metadata_interactions!

          assert_equal %w[read search-type].sort, @metadata_interactions.fetch("Patient").sort
          refute_includes @metadata_interactions.keys, "ServiceRequest"
          refute_includes @metadata_interactions.keys, "Immunization"
          refute_includes @metadata_interactions.fetch("Patient"), "create"
        end
      end

      test "restricted backend metadata keeps stock Patient read and search-type advertised" do
        with_restricted_backend(capabilities: []) do
          load_metadata_interactions!

          interactions = @metadata_interactions.fetch("Patient")
          assert_includes interactions, "read"
          assert_includes interactions, "search-type"
        end
      end

      BackendRegistry::CAPABILITIES.each do |capability|
        pairs = BackendRegistry::CAPABILITY_FHIR_INTERACTIONS.fetch(capability)
        next if pairs.empty?

        test "metadata reflects #{capability} when it is the only capability provided" do
          with_restricted_backend(capabilities: [ capability ]) do
            load_metadata_interactions!

            pairs.each do |type, interaction|
              assert_includes @metadata_interactions.fetch(type, []), interaction,
                              "expected #{type} #{interaction} with #{capability}"
            end

            absent_pairs = BackendRegistry::CAPABILITY_FHIR_INTERACTIONS.flat_map do |other, other_pairs|
              other == capability ? [] : other_pairs
            end
            absent_pairs.each do |type, interaction|
              refute_includes @metadata_interactions.fetch(type, []), interaction,
                              "did not expect #{type} #{interaction} with only #{capability}"
            end

            absent_pairs.map(&:first).uniq.each do |type|
              next if pairs.any? { |pair_type, _| pair_type == type }

              if type == "Patient"
                assert_equal %w[read search-type].sort, @metadata_interactions.fetch("Patient").sort
                refute_includes @metadata_interactions.fetch("Patient"), "create"
                next
              end

              refute_includes @metadata_interactions.keys, type,
                              "did not expect a #{type} resource entry with only #{capability}"
            end
          end
        end
      end

      CAPABILITY_SUBSETS.each do |capabilities|
        label = capabilities.empty? ? "none" : (capabilities == BackendRegistry::CAPABILITIES ? "all" : capabilities.first.to_s)

        test "metadata advertised gated interactions match BackendRegistry for capability subset #{label}" do
          exercise_backend(capabilities) do
            load_metadata_interactions!

            REGISTRY_GATED_TYPES.each do |type|
              next unless BackendRegistry.supported_fhir_resource_types.include?(type)

              expected = BackendRegistry.supported_fhir_interactions(type).sort
              assert_equal expected, @metadata_interactions.fetch(type, []).sort,
                           "#{type} metadata vs registry for #{label}"
            end
          end
        end

        test "every registry-supported gated interaction appears in metadata for capability subset #{label}" do
          exercise_backend(capabilities) do
            load_metadata_interactions!

            BackendRegistry.supported_fhir_resource_types.each do |type|
              next unless REGISTRY_GATED_TYPES.include?(type)

              BackendRegistry.supported_fhir_interactions(type).each do |interaction|
                assert_includes @metadata_interactions.fetch(type, []), interaction,
                                "registry lists #{type} #{interaction} but metadata does not (#{label})"
              end
            end
          end
        end

        test "every metadata gated interaction is served on the wire for capability subset #{label}" do
          exercise_backend(capabilities) do
            load_metadata_interactions!

            REGISTRY_GATED_TYPES.each do |type|
              @metadata_interactions.fetch(type, []).each do |interaction|
                next unless BackendRegistry.capability_for_fhir_interaction(type, interaction)

                refute wire_interaction_not_supported?(type, interaction),
                       "#{type} #{interaction} advertised on metadata but answers not-supported (#{label})"
              end
            end
          end
        end
      end

      test "Patient read and search-type answer on the wire without any IHS capability" do
        with_restricted_backend(capabilities: []) do
          get "#{ENGINE}/Patient/1", headers: @fhir_headers
          assert_response :ok, response.body
          get "#{ENGINE}/Patient", params: { _id: "1" }, headers: @fhir_headers
          assert_response :ok, response.body
        end
      end

      test "restricted backend scopes_supported omits gated types and matches Patient interactions from metadata" do
        with_restricted_backend(capabilities: []) do
          load_metadata_interactions!
          load_scopes_supported!

          assert_equal expected_scopes_supported_from_metadata(@metadata_interactions), @scopes_supported.sort
          assert_includes @scopes_supported, "system/Patient.rs"
          refute_includes @scopes_supported, "system/Patient.crs"
          refute @scopes_supported.any? { |scope| scope.start_with?("system/ServiceRequest.") }
          refute @scopes_supported.any? { |scope| scope.start_with?("system/Immunization.") }
        end
      end

      CAPABILITY_SUBSETS.each do |capabilities|
        label = capabilities.empty? ? "none" : (capabilities == BackendRegistry::CAPABILITIES ? "all" : capabilities.first.to_s)

        test "scopes_supported per-type system scopes match live metadata for capability subset #{label}" do
          exercise_backend(capabilities) do
            load_metadata_interactions!
            load_scopes_supported!

            assert_equal expected_scopes_supported_from_metadata(@metadata_interactions), @scopes_supported.sort,
                         "smart-configuration must list the same system/<Type>.<perms> as /metadata (#{label})"
          end
        end
      end

      test "default backend scopes_supported still advertises IHS-gated types present on metadata" do
        load_metadata_interactions!
        load_scopes_supported!

        assert_includes @scopes_supported, "system/ServiceRequest.s"
        assert_includes @scopes_supported, "system/Immunization.s"
        assert_includes @scopes_supported, "system/Patient.crs"
      end

      private

      def exercise_backend(capabilities, &block)
        if capabilities == BackendRegistry::CAPABILITIES
          yield
        else
          with_restricted_backend(capabilities: capabilities, &block)
        end
      end

      def load_metadata_interactions!
        get METADATA
        assert_response :ok
        @metadata_interactions = metadata_resources_by_type.transform_values do |resource|
          Array(resource["interaction"]).map { |entry| entry["code"] }
        end
      end

      def load_scopes_supported!
        get SMART_CONFIGURATION
        assert_response :ok
        @scopes_supported = JSON.parse(response.body).fetch("scopes_supported")
      end

      def expected_scopes_supported_from_metadata(metadata_interactions)
        per_type = metadata_interactions.sort.map do |type, interactions|
          permissions = INTERACTIONS_FOR_SCOPE_ORDER.filter_map do |code|
            INTERACTION_TO_SCOPE_PERMISSION[code] if interactions.include?(code)
          end.join
          next if permissions.empty?

          "system/#{type}.#{permissions}"
        end
        [ READ_SCOPE_WILDCARD, *per_type ].sort
      end

      def metadata_statement
        JSON.parse(response.body)
      end

      def metadata_resources_by_type
        rest = metadata_statement.fetch("rest").first
        rest.fetch("resource").index_by { |resource| resource["type"] }
      end

      def wire_interaction_not_supported?(type, interaction)
        case interaction
        when "read"
          get "#{ENGINE}/#{type}/#{read_probe_id(type)}", headers: @fhir_headers
        when "search-type"
          params = type == "Patient" ? { _id: "1" } : { patient: "1" }
          get "#{ENGINE}/#{type}", params: params, headers: @fhir_headers
        when "create"
          post "#{ENGINE}/#{type}",
            params: minimal_create_body(type),
            headers: @fhir_headers.merge("Content-Type" => "application/fhir+json")
        else
          flunk "no wire probe for #{type} #{interaction}"
        end

        return false unless response.not_found?

        body = JSON.parse(response.body)
        body["resourceType"] == "OperationOutcome" &&
          body.dig("issue", 0, "code") == "not-supported"
      rescue JSON::ParserError
        false
      end

      def read_probe_id(type)
        type == "Patient" ? "1" : "1"
      end

      def minimal_create_body(type)
        return registration_patient_json if type == "Patient"

        { resourceType: type }.to_json
      end

      def registration_patient_json
        {
          resourceType: "Patient",
          name: [ { family: "SPEC", given: [ "SYNTH" ] } ],
          gender: "female",
          birthDate: "1985-06-15"
        }.to_json
      end
    end
  end
end
