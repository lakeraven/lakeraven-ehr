# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # Pins the CapabilityStatement source of truth for #574: each IHS capability
    # names the FHIR resource types it owns; the supported set is filtered by
    # BackendRegistry.current.provides?.
    class FeatureAvailabilityTest < ActiveSupport::TestCase
      include IhsFeatureAvailabilityTestHelper

      teardown { teardown_restricted_backend }

      PINNED_CAPABILITY_FHIR_RESOURCES = {
        prc_referrals: %w[ServiceRequest],
        tribal_enrollment: [],
        bprm_registration: %w[Patient],
        bprm_scheduling: [],
        ihs_immunization: %w[Immunization],
        pcc_screens: []
      }.freeze

      test "each registered capability maps to the FHIR types it owns" do
        assert_equal PINNED_CAPABILITY_FHIR_RESOURCES,
                     BackendRegistry.capability_fhir_resource_types
      end

      test "supported_fhir_resource_types on rpms lists every IHS-owned type" do
        expected = %w[Immunization Patient ServiceRequest]
        assert_equal expected.sort, BackendRegistry.supported_fhir_resource_types.sort
      end

      test "supported_fhir_resource_types is empty when the backend provides no IHS capabilities" do
        with_restricted_backend(capabilities: []) do
          assert_empty BackendRegistry.supported_fhir_resource_types
        end
      end

      test "supported_fhir_resource_types reflects a partial capability set" do
        with_restricted_backend(capabilities: [ :ihs_immunization ]) do
          assert_equal %w[Immunization], BackendRegistry.supported_fhir_resource_types
        end
      end
    end
  end
end
