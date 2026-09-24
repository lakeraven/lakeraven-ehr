# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class CarePlanTest < ActiveSupport::TestCase
      test "has care plan attributes" do
        cp = CarePlan.new(
          ien: "1", patient_dfn: "100",
          title: "Diabetes Management Plan",
          description: "Comprehensive diabetes care",
          status: "active", intent: "plan",
          category: "assess-plan"
        )
        assert_equal "Diabetes Management Plan", cp.title
        assert_equal "Comprehensive diabetes care", cp.description
        assert_equal "assess-plan", cp.category
      end

      test "defaults status to active" do
        assert_equal "active", CarePlan.new.status
      end

      test "defaults intent to plan" do
        assert_equal "plan", CarePlan.new.intent
      end

      test "active? for active status" do
        assert CarePlan.new(status: "active").active?
      end

      test "active? false for completed" do
        refute CarePlan.new(status: "completed").active?
      end

      test "stores period dates" do
        cp = CarePlan.new(
          period_start: Date.new(2024, 1, 1),
          period_end: Date.new(2024, 12, 31)
        )
        assert_equal Date.new(2024, 1, 1), cp.period_start
        assert_equal Date.new(2024, 12, 31), cp.period_end
      end

      test "stores author_name" do
        cp = CarePlan.new(author_name: "Dr. Smith")
        assert_equal "Dr. Smith", cp.author_name
      end

      test "to_fhir returns CarePlan resource" do
        cp = CarePlan.new(ien: "42", patient_dfn: "100", status: "active", intent: "plan")
        fhir = cp.to_fhir
        assert_equal "CarePlan", fhir[:resourceType]
        assert_equal "42", fhir[:id]
        assert_equal "active", fhir[:status]
        assert_equal "plan", fhir[:intent]
      end

      test "to_fhir includes title" do
        cp = CarePlan.new(ien: "1", title: "Diabetes Plan")
        fhir = cp.to_fhir
        assert_equal "Diabetes Plan", fhir[:title]
      end

      test "to_fhir includes subject" do
        cp = CarePlan.new(ien: "1", patient_dfn: "100")
        fhir = cp.to_fhir
        assert_equal "Patient/100", fhir.dig(:subject, :reference)
      end

      # -- Validations (ported from rpms_redux) ----------------------------------

      test "validates patient_dfn presence" do
        cp = CarePlan.new(title: "Care Plan")
        assert_not cp.valid?
        assert_includes cp.errors[:patient_dfn], "can't be blank"
      end

      test "validates status inclusion" do
        cp = CarePlan.new(patient_dfn: "1", status: "invalid")
        assert_not cp.valid?
        assert_includes cp.errors[:status], "is not included in the list"
      end

      test "allows valid status values" do
        %w[draft active on-hold revoked completed entered-in-error unknown].each do |s|
          cp = CarePlan.new(patient_dfn: "1", status: s)
          assert cp.valid?, "Expected #{s} to be valid"
        end
      end

      test "validates intent inclusion" do
        cp = CarePlan.new(patient_dfn: "1", intent: "invalid")
        assert_not cp.valid?
        assert_includes cp.errors[:intent], "is not included in the list"
      end

      test "allows valid intent values" do
        %w[proposal plan order option].each do |i|
          cp = CarePlan.new(patient_dfn: "1", intent: i)
          assert cp.valid?, "Expected #{i} to be valid"
        end
      end

      # -- FHIR extras (ported from rpms_redux) ----------------------------------

      test "to_fhir includes category coding" do
        cp = CarePlan.new(ien: "1", patient_dfn: "100", category: "assess-plan")
        fhir = cp.to_fhir
        coding = fhir[:category].first[:coding].first
        assert_equal "assess-plan", coding[:code]
        assert_equal "http://hl7.org/fhir/us/core/CodeSystem/careplan-category", coding[:system]
      end

      test "to_fhir includes period" do
        cp = CarePlan.new(
          ien: "1", patient_dfn: "100",
          period_start: Date.new(2026, 1, 1), period_end: Date.new(2026, 12, 31)
        )
        fhir = cp.to_fhir
        assert_equal "2026-01-01", fhir[:period][:start]
        assert_equal "2026-12-31", fhir[:period][:end]
      end

      test "to_fhir includes description" do
        cp = CarePlan.new(ien: "1", patient_dfn: "100", description: "Monitor blood glucose")
        fhir = cp.to_fhir
        assert_equal "Monitor blood glucose", fhir[:description]
      end

      test "to_fhir includes author when author_name present" do
        cp = CarePlan.new(ien: "1", patient_dfn: "100", author_name: "Dr. Smith")
        fhir = cp.to_fhir
        assert_equal "Dr. Smith", fhir[:author][:display]
      end

      test "persisted? true when ien present" do
        assert CarePlan.new(ien: "1", patient_dfn: "1").persisted?
      end

      test "persisted? false when ien blank" do
        refute CarePlan.new(patient_dfn: "1").persisted?
      end
    end
  end
end
