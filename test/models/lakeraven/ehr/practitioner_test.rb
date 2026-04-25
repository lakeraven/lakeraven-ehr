# frozen_string_literal: true

require "test_helper"
require "ostruct"

module Lakeraven
  module EHR
    class PractitionerTest < ActiveSupport::TestCase
      # -- find_by_ien -----------------------------------------------------------

      test "find_by_ien returns a Practitioner for a known IEN" do
        prac = Practitioner.find_by_ien(101)
        assert_not_nil prac
        assert_kind_of Practitioner, prac
        assert_equal 101, prac.ien
        assert_equal "MARTINEZ,SARAH", prac.name
        assert_equal "Cardiology", prac.specialty
        assert_equal "1234567890", prac.npi
        assert_equal "Physician", prac.provider_class
      end

      test "find_by_ien returns nil for unknown IEN" do
        assert_nil Practitioner.find_by_ien(99_999)
      end

      test "find_by_ien returns nil for nil" do
        assert_nil Practitioner.find_by_ien(nil)
      end

      # -- search ----------------------------------------------------------------

      test "search returns practitioners matching name pattern" do
        results = Practitioner.search("MARTINEZ")
        assert_equal 1, results.length
        assert_equal "MARTINEZ,SARAH", results.first.name
      end

      test "search with empty string returns all practitioners" do
        results = Practitioner.search("")
        assert_equal 2, results.length
      end

      test "search returns empty array for no matches" do
        assert_equal [], Practitioner.search("ZZZZNONEXISTENT")
      end

      # -- composite fields ------------------------------------------------------

      test "name syncs to first_name and last_name" do
        prac = Practitioner.new(name: "CHEN,JAMES")
        assert_equal "Chen", prac.last_name
        assert_equal "James", prac.first_name
      end

      test "first_name and last_name sync to name" do
        prac = Practitioner.new(first_name: "Sarah", last_name: "Martinez")
        assert_equal "Martinez,Sarah", prac.name
      end

      # -- display_name ----------------------------------------------------------

      test "display_name formats MUMPS name for display" do
        prac = Practitioner.new(name: "MARTINEZ,SARAH")
        assert_equal "SARAH MARTINEZ", prac.display_name
      end

      # -- persisted? ------------------------------------------------------------

      test "persisted? true with valid IEN" do
        prac = Practitioner.new(ien: 101, name: "TEST,DOC")
        assert prac.persisted?
      end

      test "persisted? false without IEN" do
        prac = Practitioner.new(name: "TEST,DOC")
        refute prac.persisted?
      end

      # -- credential helpers ----------------------------------------------------

      test "can_prescribe_controlled? true with DEA number" do
        prac = Practitioner.new(dea_number: "AB1234567")
        assert prac.can_prescribe_controlled?
      end

      test "can_prescribe_controlled? false without DEA" do
        prac = Practitioner.new(dea_number: nil)
        refute prac.can_prescribe_controlled?
      end

      test "credentials_summary combines title and specialty" do
        prac = Practitioner.new(title: "MD", specialty: "Cardiology")
        assert_equal "MD, Cardiology", prac.credentials_summary
      end

      test "credentials_summary handles missing title" do
        prac = Practitioner.new(specialty: "Cardiology")
        assert_equal "Cardiology", prac.credentials_summary
      end

      # -- to_fhir ---------------------------------------------------------------

      test "to_fhir returns a FHIR Practitioner hash" do
        prac = Practitioner.find_by_ien(101)
        fhir = prac.to_fhir

        assert_equal "Practitioner", fhir[:resourceType]
        assert_equal "101", fhir[:id]
        assert_equal "MARTINEZ", fhir[:name].first[:family]
      end

      test "to_fhir includes NPI identifier" do
        prac = Practitioner.find_by_ien(101)
        fhir = prac.to_fhir

        npi_id = fhir[:identifier].find { |id| id[:system]&.include?("npi") }
        assert_equal "1234567890", npi_id[:value]
      end

      test "to_fhir includes qualification" do
        prac = Practitioner.find_by_ien(101)
        fhir = prac.to_fhir

        assert prac.to_fhir[:qualification]&.any?
      end

      test "to_fhir includes telecom" do
        prac = Practitioner.find_by_ien(101)
        fhir = prac.to_fhir

        telecom = fhir[:telecom]&.first
        assert_equal "907-555-9999", telecom[:value]
      end

      # -- edge cases ----------------------------------------------------------

      test "handles practitioners with minimal data" do
        prac = Practitioner.new(ien: 999, name: "MINIMAL,PROVIDER")
        assert_equal "MINIMAL,PROVIDER", prac.name
        refute prac.can_prescribe_controlled?
      end

      test "display_name handles single-part name" do
        prac = Practitioner.new(name: "SINGLENAME")
        assert_equal "SINGLENAME", prac.display_name
      end

      test "display_name handles blank name" do
        prac = Practitioner.new(name: "")
        assert_equal "", prac.display_name
      end

      test "credentials_summary with both title and specialty" do
        prac = Practitioner.new(title: "MD", specialty: "Cardiology")
        assert_equal "MD, Cardiology", prac.credentials_summary
      end

      test "credentials_summary with only specialty" do
        prac = Practitioner.new(specialty: "Cardiology")
        assert_equal "Cardiology", prac.credentials_summary
      end

      test "credentials_summary with only title" do
        prac = Practitioner.new(title: "RN")
        assert_equal "RN", prac.credentials_summary
      end

      test "credentials_summary with neither" do
        prac = Practitioner.new
        assert_equal "", prac.credentials_summary
      end

      test "find_by_ien returns nil for zero" do
        assert_nil Practitioner.find_by_ien(0)
      end

      test "find_by_ien returns nil for negative" do
        assert_nil Practitioner.find_by_ien(-1)
      end

      test "to_fhir for practitioner without NPI" do
        prac = Practitioner.new(ien: 102, name: "NURSE,HEAD", title: "RN")
        fhir = prac.to_fhir
        assert_equal "Practitioner", fhir[:resourceType]
      end

      test "name syncs from MUMPS format with middle name" do
        prac = Practitioner.new(name: "DOE,JOHN MICHAEL")
        assert_equal "Doe", prac.last_name
        assert_equal "John michael", prac.first_name
      end

      # -- resource_class --------------------------------------------------------

      test "resource_class returns Practitioner" do
        assert_equal "Practitioner", Practitioner.resource_class
      end

      # -- from_fhir_attributes --------------------------------------------------

      test "from_fhir_attributes extracts attributes from FHIR resource" do
        fhir_resource = OpenStruct.new(
          name: [OpenStruct.new(family: "SMITH", given: ["JANE", "M"])],
          identifier: [
            OpenStruct.new(system: "http://hl7.org/fhir/sid/us-npi", value: "9876543210")
          ],
          qualification: [
            OpenStruct.new(code: OpenStruct.new(text: "EMERGENCY MEDICINE"))
          ]
        )

        attributes = Practitioner.from_fhir_attributes(fhir_resource)

        assert_equal "SMITH, JANE M", attributes[:name]
        assert_equal "9876543210", attributes[:npi]
        assert_equal "EMERGENCY MEDICINE", attributes[:specialty]
      end

      test "from_fhir_attributes handles missing data" do
        fhir_resource = OpenStruct.new(
          name: [OpenStruct.new(family: "DOE")],
          identifier: [],
          qualification: []
        )

        attributes = Practitioner.from_fhir_attributes(fhir_resource)

        assert_equal "DOE", attributes[:name]
        assert_nil attributes[:npi]
        assert_nil attributes[:specialty]
      end

      # -- FHIR parsing helpers --------------------------------------------------

      test "extract_name_from_fhir handles family and given names" do
        fhir_resource = OpenStruct.new(
          name: [OpenStruct.new(family: "DOE", given: ["JOHN", "MICHAEL"])]
        )
        assert_equal "DOE, JOHN MICHAEL", Practitioner.extract_name_from_fhir(fhir_resource)
      end

      test "extract_name_from_fhir handles family name only" do
        fhir_resource = OpenStruct.new(
          name: [OpenStruct.new(family: "DOE", given: nil)]
        )
        assert_equal "DOE", Practitioner.extract_name_from_fhir(fhir_resource)
      end

      test "extract_name_from_fhir handles empty names" do
        assert_nil Practitioner.extract_name_from_fhir(OpenStruct.new(name: []))
        assert_nil Practitioner.extract_name_from_fhir(OpenStruct.new(name: nil))
      end

      test "extract_npi_from_fhir finds NPI identifier" do
        fhir_resource = OpenStruct.new(
          identifier: [
            OpenStruct.new(system: "http://ihs.gov/rpms/provider-id", value: "101"),
            OpenStruct.new(system: "http://hl7.org/fhir/sid/us-npi", value: "1234567890"),
            OpenStruct.new(system: "other-system", value: "other-value")
          ]
        )
        assert_equal "1234567890", Practitioner.extract_npi_from_fhir(fhir_resource)
      end

      test "extract_npi_from_fhir returns nil when no NPI" do
        fhir_resource = OpenStruct.new(
          identifier: [OpenStruct.new(system: "other-system", value: "other-value")]
        )
        assert_nil Practitioner.extract_npi_from_fhir(fhir_resource)
      end

      test "extract_npi_from_fhir returns nil for empty identifiers" do
        assert_nil Practitioner.extract_npi_from_fhir(OpenStruct.new(identifier: []))
      end

      test "extract_specialty_from_fhir finds specialty" do
        fhir_resource = OpenStruct.new(
          qualification: [OpenStruct.new(code: OpenStruct.new(text: "CARDIOLOGY"))]
        )
        assert_equal "CARDIOLOGY", Practitioner.extract_specialty_from_fhir(fhir_resource)
      end

      test "extract_specialty_from_fhir returns nil for empty qualifications" do
        assert_nil Practitioner.extract_specialty_from_fhir(OpenStruct.new(qualification: []))
        assert_nil Practitioner.extract_specialty_from_fhir(OpenStruct.new(qualification: nil))
      end

      # -- to_fhir missing optional data -----------------------------------------

      test "to_fhir handles missing optional data" do
        prac = Practitioner.new(
          ien: 999,
          name: "BARE,MINIMUM",
          npi: nil,
          dea_number: nil,
          specialty: nil,
          service_section: nil,
          title: nil,
          phone: nil
        )
        fhir = prac.to_fhir

        assert_equal "Practitioner", fhir[:resourceType]
        # Only RPMS ID when no NPI
        rpms_ids = fhir[:identifier]&.select { |id| id[:system]&.include?("rpms") }
        assert rpms_ids&.any?, "Should have RPMS identifier"
        npi_ids = fhir[:identifier]&.select { |id| id[:system]&.include?("npi") } || []
        assert_empty npi_ids, "Should not have NPI identifier"
        assert_empty(fhir[:qualification] || [])
        assert_empty(fhir[:telecom] || [])
      end

      # -- can_prescribe_controlled? with empty string ---------------------------

      test "can_prescribe_controlled? false with empty string" do
        prac = Practitioner.new(dea_number: "")
        refute prac.can_prescribe_controlled?
      end

      # -- persisted? with zero IEN ----------------------------------------------

      test "persisted? false with zero IEN" do
        prac = Practitioner.new(ien: 0, name: "TEST,DOC")
        refute prac.persisted?
      end

      # -- unicode and edge cases ------------------------------------------------

      test "handles unicode characters in names" do
        prac = Practitioner.new(name: "GARCIA,JOSE")
        assert_equal "JOSE GARCIA", prac.display_name
      end

      test "handles very long names" do
        long_name = "A" * 100 + "," + "B" * 100
        prac = Practitioner.new(name: long_name)
        assert prac.display_name.length > 200
      end

      # -- FHIR includes RPMS identifier -----------------------------------------

      test "to_fhir includes RPMS identifier for provenance" do
        prac = Practitioner.new(ien: 101, name: "DOE,JOHN", npi: "2222222222")
        fhir = prac.to_fhir

        rpms_id = fhir[:identifier]&.find { |id| id[:system]&.include?("rpms") }
        npi_id = fhir[:identifier]&.find { |id| id[:system]&.include?("npi") }

        assert_not_nil rpms_id, "Should have RPMS identifier"
        assert_not_nil npi_id, "Should have NPI identifier"
      end

      # -- to_fhir includes given names ------------------------------------------

      test "to_fhir includes given names" do
        prac = Practitioner.new(ien: 101, name: "DOE,JOHN MICHAEL")
        fhir = prac.to_fhir

        name = fhir[:name]&.first
        assert_equal "DOE", name[:family]
        assert_includes name[:given], "JOHN"
      end

      test "to_fhir includes US Core profile" do
        prac = Practitioner.new(ien: 101, name: "DOE,JOHN")
        fhir = prac.to_fhir

        assert fhir[:meta][:profile].include?(
          "http://hl7.org/fhir/us/core/StructureDefinition/us-core-practitioner"
        )
      end
    end
  end
end
