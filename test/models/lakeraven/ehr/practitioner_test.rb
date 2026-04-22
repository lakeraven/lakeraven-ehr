# frozen_string_literal: true

require "test_helper"

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
    end
  end
end
