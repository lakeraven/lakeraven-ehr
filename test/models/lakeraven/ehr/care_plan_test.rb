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
    end
  end
end
