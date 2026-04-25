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

      # -- SDOH constants --------------------------------------------------------

      test "defines SDOH_CODES constant" do
        assert_equal "71802-3", Observation::SDOH_CODES[:housing_status]
        assert_equal "88122-7", Observation::SDOH_CODES[:food_insecurity]
        assert_equal "93025-5", Observation::SDOH_CODES[:prapare]
        assert_equal "96777-8", Observation::SDOH_CODES[:ahc_hrsn]
        assert_equal "76513-1", Observation::SDOH_CODES[:financial_strain]
        assert_equal "67875-5", Observation::SDOH_CODES[:employment_status]
      end

      test "defines SOGI_CODES constant" do
        assert_equal "76690-7", Observation::SOGI_CODES[:sexual_orientation]
        assert_equal "76691-5", Observation::SOGI_CODES[:gender_identity]
      end

      test "sdoh? for social-history category" do
        assert Observation.new(category: "social-history").sdoh?
      end

      test "sdoh? for survey category" do
        assert Observation.new(category: "survey").sdoh?
      end

      test "sdoh? false for vital-signs" do
        refute Observation.new(category: "vital-signs").sdoh?
      end

      # -- SDOH FHIR serialization -----------------------------------------------

      test "social-history observation to_fhir includes category coding with system" do
        obs = Observation.new(
          ien: "sdoh-1", patient_dfn: "1", category: "social-history",
          code: "71802-3", display: "Housing status", value: "Permanently housed", status: "final"
        )
        fhir = obs.to_fhir
        coding = fhir[:category].first[:coding].first
        assert_equal "http://terminology.hl7.org/CodeSystem/observation-category", coding[:system]
        assert_equal "social-history", coding[:code]
      end

      test "sdoh observation to_fhir includes LOINC code system" do
        obs = Observation.new(
          ien: "sdoh-1", patient_dfn: "1", category: "social-history",
          code: "71802-3", display: "Housing status", status: "final"
        )
        fhir = obs.to_fhir
        assert_equal "http://loinc.org", fhir.dig(:code, :coding, 0, :system)
      end

      test "sdoh observation to_fhir includes valueString" do
        obs = Observation.new(
          ien: "sdoh-1", patient_dfn: "1", category: "social-history",
          code: "71802-3", display: "Housing status",
          value: "Permanently housed", status: "final"
        )
        fhir = obs.to_fhir
        assert_equal "Permanently housed", fhir[:valueString]
      end

      # -- Vital signs -----------------------------------------------------------

      test "defines VITAL_SIGNS_CODES constant" do
        assert Observation::VITAL_SIGNS_CODES[:blood_pressure].present?
        assert Observation::VITAL_SIGNS_CODES[:heart_rate].present?
        assert Observation::VITAL_SIGNS_CODES[:temperature].present?
        assert Observation::VITAL_SIGNS_CODES[:systolic].present?
        assert Observation::VITAL_SIGNS_CODES[:diastolic].present?
      end

      test "blood pressure to_fhir uses component pattern" do
        bp = Observation.new(
          ien: "bp-1", patient_dfn: "1", category: "vital-signs",
          code: Observation::VITAL_SIGNS_CODES[:blood_pressure],
          display: "Blood Pressure", value: "120/80", status: "final"
        )
        fhir = bp.to_fhir
        assert fhir[:component].present?, "Blood pressure should use component pattern"
        assert_nil fhir[:valueQuantity], "Blood pressure should not have flat valueQuantity"
      end

      test "blood pressure components have systolic and diastolic codes" do
        bp = Observation.new(
          ien: "bp-1", patient_dfn: "1", category: "vital-signs",
          code: Observation::VITAL_SIGNS_CODES[:blood_pressure],
          display: "Blood Pressure", value: "120/80", status: "final"
        )
        fhir = bp.to_fhir
        codes = fhir[:component].map { |c| c.dig(:code, :coding, 0, :code) }
        assert_includes codes, Observation::VITAL_SIGNS_CODES[:systolic]
        assert_includes codes, Observation::VITAL_SIGNS_CODES[:diastolic]
      end

      test "blood pressure components have mm[Hg] unit" do
        bp = Observation.new(
          ien: "bp-1", patient_dfn: "1", category: "vital-signs",
          code: Observation::VITAL_SIGNS_CODES[:blood_pressure],
          display: "Blood Pressure", value: "120/80", status: "final"
        )
        fhir = bp.to_fhir
        fhir[:component].each do |component|
          assert_equal "mm[Hg]", component[:valueQuantity][:unit]
          assert_equal "http://unitsofmeasure.org", component[:valueQuantity][:system]
        end
      end

      test "heart rate to_fhir has /min unit" do
        hr = Observation.new(
          ien: "hr-1", patient_dfn: "1", category: "vital-signs",
          code: Observation::VITAL_SIGNS_CODES[:heart_rate],
          display: "Heart Rate", value: "72", value_quantity: "72",
          unit: "/min", status: "final"
        )
        fhir = hr.to_fhir
        assert_equal "/min", fhir[:valueQuantity][:unit]
      end

      test "vital-signs category coding includes system" do
        hr = Observation.new(
          ien: "hr-1", patient_dfn: "1", category: "vital-signs",
          code: Observation::VITAL_SIGNS_CODES[:heart_rate],
          display: "Heart Rate", value: "72", value_quantity: "72",
          unit: "/min", status: "final"
        )
        fhir = hr.to_fhir
        coding = fhir[:category].first[:coding].first
        assert_equal "http://terminology.hl7.org/CodeSystem/observation-category", coding[:system]
        assert_equal "vital-signs", coding[:code]
      end
    end
  end
end
