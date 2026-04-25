# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class ObservationTest < ActiveSupport::TestCase
      test "has observation attributes" do
        obs = Observation.new(
          ien: "1", patient_dfn: "100", code: "8480-6",
          display: "Systolic blood pressure", value: "120",
          value_quantity: "120", unit: "mmHg",
          category: "vital-signs", status: "final"
        )
        assert_equal "8480-6", obs.code
        assert_equal "120", obs.value
        assert_equal "mmHg", obs.unit
      end

      test "vital_sign? for vital-signs category" do
        assert Observation.new(category: "vital-signs").vital_sign?
      end

      test "vital_sign? false for laboratory" do
        refute Observation.new(category: "laboratory").vital_sign?
      end

      test "laboratory? for laboratory category" do
        assert Observation.new(category: "laboratory").laboratory?
      end

      test "laboratory? false for vital-signs" do
        refute Observation.new(category: "vital-signs").laboratory?
      end

      test "stores effective_datetime" do
        dt = DateTime.new(2024, 3, 15, 14, 30)
        obs = Observation.new(effective_datetime: dt)
        assert_equal dt, obs.effective_datetime
      end

      test "for_patient returns array" do
        results = Observation.for_patient(1)
        assert_kind_of Array, results
      end

      # -- Gateway DI ----------------------------------------------------------

      test "gateway is configurable" do
        assert Observation.respond_to?(:gateway)
        assert Observation.respond_to?(:gateway=)
      end

      test "gateway defaults to ObservationGateway" do
        assert_equal ObservationGateway, Observation.gateway
      end

      test "for_patient delegates to gateway" do
        mock_gw = Object.new
        def mock_gw.for_patient(_dfn)
          [ Lakeraven::EHR::Observation.new(ien: "99", display: "MOCK BP") ]
        end

        original = Observation.gateway
        begin
          Observation.gateway = mock_gw
          results = Observation.for_patient(1)
          assert_equal 1, results.length
          assert_equal "MOCK BP", results.first.display
        ensure
          Observation.gateway = original
        end
      end

      test "to_fhir returns Observation resource" do
        obs = Observation.new(ien: "42", patient_dfn: "100", status: "final")
        fhir = obs.to_fhir
        assert_equal "Observation", fhir[:resourceType]
        assert_equal "42", fhir[:id]
        assert_equal "final", fhir[:status]
      end

      test "to_fhir includes subject reference" do
        obs = Observation.new(ien: "1", patient_dfn: "100")
        fhir = obs.to_fhir
        assert_equal "Patient/100", fhir.dig(:subject, :reference)
      end

      test "to_fhir includes code" do
        obs = Observation.new(ien: "1", code: "8480-6", display: "Systolic BP")
        fhir = obs.to_fhir
        assert_equal "8480-6", fhir.dig(:code, :coding, 0, :code)
        assert_equal "Systolic BP", fhir.dig(:code, :text)
      end

      test "to_fhir includes valueQuantity" do
        obs = Observation.new(ien: "1", value_quantity: "120", unit: "mmHg")
        fhir = obs.to_fhir
        assert_equal "120", fhir.dig(:valueQuantity, :value)
        assert_equal "mmHg", fhir.dig(:valueQuantity, :unit)
      end

      test "to_fhir includes category" do
        obs = Observation.new(ien: "1", category: "vital-signs")
        fhir = obs.to_fhir
        assert fhir[:category]&.any?
      end
    end
  end
end
