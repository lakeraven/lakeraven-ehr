# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class DecoratorTest < ActiveSupport::TestCase
      teardown do
        PatientSupplement.delete_all
      end

      # -- BaseDecorator DSL ---------------------------------------------------

      test "decorator delegates to wrapped model" do
        patient = Patient.new(dfn: 1, name: "DOE,JOHN", sex: "M")
        decorated = PatientDecorator.new(patient)

        assert_equal 1, decorated.dfn
        assert_equal "DOE,JOHN", decorated.name
        assert_equal "M", decorated.sex
      end

      test "decorator exposes supplement fields" do
        PatientSupplement.create!(patient_dfn: 1, sexual_orientation: "Straight", gender_identity: "Male")

        patient = Patient.new(dfn: 1, name: "DOE,JOHN", sex: "M")
        decorated = PatientDecorator.new(patient)

        assert_equal "Straight", decorated.sexual_orientation
        assert_equal "Male", decorated.gender_identity
      end

      test "supplement fields return nil when no supplement exists" do
        patient = Patient.new(dfn: 1, name: "DOE,JOHN", sex: "M")
        decorated = PatientDecorator.new(patient)

        assert_nil decorated.sexual_orientation
        assert_nil decorated.gender_identity
      end

      test "supplement data is lazy loaded and cached" do
        PatientSupplement.create!(patient_dfn: 1, sexual_orientation: "Straight")

        patient = Patient.new(dfn: 1, name: "DOE,JOHN", sex: "M")
        decorated = PatientDecorator.new(patient)

        # First access loads
        assert_equal "Straight", decorated.sexual_orientation
        # Second access uses cache (no additional query)
        assert_equal "Straight", decorated.sexual_orientation
      end

      test "save_supplement! persists SOGI data" do
        patient = Patient.new(dfn: 1, name: "DOE,JOHN", sex: "M")
        decorated = PatientDecorator.new(patient)

        decorated.save_supplement!(sexual_orientation: "Straight", gender_identity: "Male")

        sup = PatientSupplement.find_by(patient_dfn: 1)
        assert_equal "Straight", sup.sexual_orientation
        assert_equal "Male", sup.gender_identity
      end

      test "save_supplement! updates existing supplement" do
        PatientSupplement.create!(patient_dfn: 1, sexual_orientation: "Unknown")

        patient = Patient.new(dfn: 1, name: "DOE,JOHN", sex: "M")
        decorated = PatientDecorator.new(patient)

        decorated.save_supplement!(sexual_orientation: "Straight")

        assert_equal "Straight", PatientSupplement.find_by(patient_dfn: 1).sexual_orientation
      end

      # -- FHIR with SOGI extensions ------------------------------------------

      test "to_fhir includes SOGI extensions from supplement" do
        PatientSupplement.create!(patient_dfn: 1, sexual_orientation: "Straight", gender_identity: "Male")

        patient = Patient.find_by_dfn(1)
        decorated = PatientDecorator.new(patient)
        fhir = decorated.to_fhir

        so_ext = fhir[:extension]&.find { |e| e[:url]&.include?("sexualOrientation") }
        gi_ext = fhir[:extension]&.find { |e| e[:url]&.include?("genderIdentity") }

        assert_equal "Straight", so_ext[:valueString]
        assert_equal "Male", gi_ext[:valueString]
      end

      test "to_fhir omits extensions when no supplement" do
        patient = Patient.find_by_dfn(1)
        decorated = PatientDecorator.new(patient)
        fhir = decorated.to_fhir

        assert_nil fhir[:extension]
      end

      # -- PatientSupplement model ---------------------------------------------

      test "PatientSupplement requires patient_dfn" do
        sup = PatientSupplement.new(sexual_orientation: "Unknown")
        assert_not sup.valid?
      end

      test "PatientSupplement enforces unique patient_dfn" do
        PatientSupplement.create!(patient_dfn: 1)
        dup = PatientSupplement.new(patient_dfn: 1)
        assert_not dup.valid?
      end
    end
  end
end
