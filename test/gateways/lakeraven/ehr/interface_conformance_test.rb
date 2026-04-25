# frozen_string_literal: true

require "test_helper"
require "lakeraven/integrations"

# Verify that lakeraven-ehr gateways conform to the interface contracts
# defined in lakeraven-integrations. These tests don't test behavior —
# they verify the method signatures exist so engines can depend on the
# interface without knowing the concrete implementation.
module Lakeraven
  module EHR
    class InterfaceConformanceTest < ActiveSupport::TestCase
      # =====================================================================
      # PatientLookup contract
      # =====================================================================

      test "PatientGateway responds to :find like PatientLookup::Base" do
        assert PatientGateway.respond_to?(:find), "PatientGateway must implement find(dfn)"
      end

      test "PatientGateway responds to :search like PatientLookup::Base" do
        assert PatientGateway.respond_to?(:search), "PatientGateway must implement search(name)"
      end

      test "PatientGateway responds to :find_by_ssn like PatientLookup::Base" do
        assert PatientGateway.respond_to?(:find_by_ssn), "PatientGateway must implement find_by_ssn(ssn)"
      end

      test "PatientGateway.find returns a Patient or nil" do
        result = PatientGateway.find(1)
        assert result.is_a?(Patient) || result.nil?, "find should return Patient or nil"
      end

      test "PatientGateway.search returns an array" do
        results = PatientGateway.search("Anderson")
        assert_kind_of Array, results
      end

      # =====================================================================
      # ClinicalDataReader contract
      # =====================================================================

      CLINICAL_GATEWAYS = {
        "AllergyIntoleranceGateway" => AllergyIntoleranceGateway,
        "ConditionGateway" => ConditionGateway,
        "MedicationRequestGateway" => MedicationRequestGateway,
        "ObservationGateway" => ObservationGateway,
        "ProcedureGateway" => ProcedureGateway,
        "ImmunizationGateway" => ImmunizationGateway,
        "EncounterGateway" => EncounterGateway
      }.freeze

      CLINICAL_GATEWAYS.each do |name, gateway_class|
        test "#{name} responds to :for_patient like ClinicalDataReader::Base" do
          assert gateway_class.respond_to?(:for_patient),
                 "#{name} must implement for_patient(dfn)"
        end

        test "#{name}.for_patient returns an array" do
          results = gateway_class.for_patient(1)
          assert_kind_of Array, results, "#{name}.for_patient should return Array"
        end
      end
    end
  end
end
