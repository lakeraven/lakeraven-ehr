# frozen_string_literal: true

require "test_helper"

class Lakeraven::EHR::PatientTest < ActiveSupport::TestCase
  # GatewayFactory defaults to mock in test env.
  # MockGatewayAdapter seeds patients DFN 1-5 on first use.

  # -- find_by_dfn -----------------------------------------------------------

  test "find_by_dfn returns a Patient for a known DFN" do
    patient = Lakeraven::EHR::Patient.find_by_dfn(1)
    assert_not_nil patient
    assert_kind_of Lakeraven::EHR::Patient, patient
    assert_equal 1, patient.dfn
    assert_equal "Anderson,Alice", patient.name
    assert_equal "F", patient.sex
  end

  test "find_by_dfn returns nil for unknown DFN" do
    assert_nil Lakeraven::EHR::Patient.find_by_dfn(99999)
  end

  test "find_by_dfn returns nil for zero" do
    assert_nil Lakeraven::EHR::Patient.find_by_dfn(0)
  end

  test "find_by_dfn returns nil for nil" do
    assert_nil Lakeraven::EHR::Patient.find_by_dfn(nil)
  end

  test "find_by_dfn merges extended demographics" do
    patient = Lakeraven::EHR::Patient.find_by_dfn(1)
    assert_equal "AMERICAN INDIAN", patient.race
    assert_equal "123 Main St", patient.address_line1
    assert_equal "AK", patient.state
    assert_equal "907-555-1234", patient.phone
    assert_equal "ANLC-12345", patient.tribal_enrollment_number
  end

  # -- search ----------------------------------------------------------------

  test "search returns patients matching name pattern" do
    results = Lakeraven::EHR::Patient.search("Anderson")
    assert_operator results.length, :>=, 1
    assert results.all? { |p| p.is_a?(Lakeraven::EHR::Patient) }
  end

  test "search returns empty array for no matches" do
    assert_equal [], Lakeraven::EHR::Patient.search("ZZZZNONEXISTENT")
  end

  # -- composite fields ------------------------------------------------------

  test "name syncs to first_name and last_name" do
    patient = Lakeraven::EHR::Patient.new(name: "DOE,JOHN")
    assert_equal "Doe", patient.last_name
    assert_equal "John", patient.first_name
  end

  test "first_name and last_name sync to name" do
    patient = Lakeraven::EHR::Patient.new(first_name: "Jane", last_name: "Smith")
    assert_equal "Smith,Jane", patient.name
  end

  # -- display_name ----------------------------------------------------------

  test "display_name formats MUMPS name for display" do
    patient = Lakeraven::EHR::Patient.new(name: "DOE,JOHN")
    assert_equal "JOHN DOE", patient.display_name
  end

  # -- to_fhir ---------------------------------------------------------------

  test "to_fhir returns a FHIR Patient hash" do
    patient = Lakeraven::EHR::Patient.find_by_dfn(1)
    fhir = patient.to_fhir

    assert_equal "Patient", fhir[:resourceType]
    assert_equal "1", fhir[:id]
    assert_includes fhir.dig(:meta, :profile), "http://hl7.org/fhir/us/core/StructureDefinition/us-core-patient"
    assert_equal "Anderson", fhir[:name].first[:family]
    assert_equal "female", fhir[:gender]
  end
end
