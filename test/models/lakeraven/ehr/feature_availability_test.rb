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
          %w[ServiceRequest read],
          %w[ServiceRequest search-type]
        ],
        tribal_enrollment: [],
        bprm_registration: [
          %w[Patient create]
        ],
        bprm_scheduling: [],
        ihs_immunization: [
          %w[Immunization read],
          %w[Immunization search-type]
        ],
        pcc_screens: []
      }.freeze

      test "each registered capability maps to the FHIR interactions it owns" do
        assert_equal PINNED_CAPABILITY_FHIR_INTERACTIONS,
                     BackendRegistry.capability_fhir_interactions
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
    end
  end
end
