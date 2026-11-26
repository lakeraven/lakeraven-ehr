# frozen_string_literal: true

require "test_helper"

# Default rpms backend: IHS surfaces keep today's behaviour (#647 regression).
class IhsFeatureRpmsRegressionTest < ActionDispatch::IntegrationTest
  include SmartAuthTestHelper
  include BrokerStubbing
  include IhsFeatureAvailabilityTestHelper

  PATIENT_DFN = "1"

  setup do
    setup_smart_auth(scopes: "system/*.read system/Patient.write")
    assert_equal :rpms, Lakeraven::EHR.configuration.backend
    seed_surface_data
  end

  teardown do
    teardown_smart_auth
  end

  test "GET ServiceRequest still returns a referral bundle on rpms" do
    get "/lakeraven-ehr/ServiceRequest", params: { patient: PATIENT_DFN }, headers: @headers
    assert_response :ok
    body = JSON.parse(response.body)
    assert_operator body.fetch("total"), :>=, 1
    assert body.fetch("entry").any? { |e| e.dig("resource", "resourceType") == "ServiceRequest" }
  end

  test "GET Immunization still returns immunization entries on rpms" do
    get "/lakeraven-ehr/Immunization", params: { patient: PATIENT_DFN }, headers: @headers
    assert_response :ok
    body = JSON.parse(response.body)
    assert body.fetch("entry").any? { |e| e.dig("resource", "resourceType") == "Immunization" }
  end

  test "chart still renders the Immunizations card on rpms" do
    get "/lakeraven-ehr/patients/#{PATIENT_DFN}", headers: @headers
    assert_response :ok
    assert_select "h2", text: /Immunizations/
    assert_includes response.body, "Synthetic COVID-19"
  end

  test "chart still renders scheduled appointment rows on rpms" do
    get "/lakeraven-ehr/patients/#{PATIENT_DFN}", headers: @headers
    assert_response :ok
    assert_includes response.body, "Scheduling Clinic Future"
    assert_includes response.body, "Stock Encounter Ward"
  end

  private

  # What the rpms-rpc reads behind these surfaces return for the patient.
  def seed_surface_data
    RpmsStandIn.answer(RpmsRpc::Referral, :for_patient, PATIENT_DFN, with: [
      { ien: "5001", patient_dfn: 1, status: "pending", date: Date.new(2026, 3, 1), provider: "SYNTH,PROVIDER" }
    ])
    RpmsStandIn.answer(RpmsRpc::Encounter, :for_patient, PATIENT_DFN, with: [
      { datetime: Date.new(2026, 2, 1), location_ien: 10, location: "Stock Encounter Ward", status: "KEPT" },
      { datetime: Date.new(2026, 5, 1), location_ien: 20, location: "Scheduling Clinic Future", status: "SCHEDULED" }
    ])
    RpmsStandIn.answer(RpmsRpc::Immunization, :for_patient, PATIENT_DFN, with: [
      { ien: "9001", vaccine_display: "Synthetic COVID-19", occurrence_datetime: Time.utc(2026, 1, 10, 9, 0, 0) }
    ])
  end

  def registration_patient_json
    {
      resourceType: "Patient",
      name: [ { family: "RPMSREG", given: [ "SYNTH" ] } ],
      gender: "female",
      birthDate: "1985-06-15"
    }.to_json
  end
end
