# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class GoalTest < ActiveSupport::TestCase
      test "has goal attributes" do
        g = Goal.new(
          ien: "1", patient_dfn: "100",
          description: "Reduce A1C to below 7%",
          lifecycle_status: "active",
          achievement_status: "in-progress",
          category: "physiological", priority: "high-priority"
        )
        assert_equal "Reduce A1C to below 7%", g.description
        assert_equal "physiological", g.category
        assert_equal "high-priority", g.priority
      end

      test "defaults lifecycle_status to active" do
        assert_equal "active", Goal.new.lifecycle_status
      end

      test "active? for active lifecycle" do
        assert Goal.new(lifecycle_status: "active").active?
      end

      test "active? false for completed" do
        refute Goal.new(lifecycle_status: "completed").active?
      end

      test "achieved? for achieved achievement_status" do
        assert Goal.new(achievement_status: "achieved").achieved?
      end

      test "achieved? false for in-progress" do
        refute Goal.new(achievement_status: "in-progress").achieved?
      end

      test "achieved? false when nil" do
        refute Goal.new(achievement_status: nil).achieved?
      end

      test "stores dates" do
        g = Goal.new(
          start_date: Date.new(2024, 1, 1),
          target_date: Date.new(2024, 6, 30)
        )
        assert_equal Date.new(2024, 1, 1), g.start_date
        assert_equal Date.new(2024, 6, 30), g.target_date
      end

      test "to_fhir returns Goal resource" do
        g = Goal.new(ien: "42", patient_dfn: "100", lifecycle_status: "active")
        fhir = g.to_fhir
        assert_equal "Goal", fhir[:resourceType]
        assert_equal "42", fhir[:id]
        assert_equal "active", fhir[:lifecycleStatus]
      end

      test "to_fhir includes description" do
        g = Goal.new(ien: "1", description: "Reduce A1C")
        fhir = g.to_fhir
        assert_equal "Reduce A1C", fhir.dig(:description, :text)
      end

      test "to_fhir includes subject" do
        g = Goal.new(ien: "1", patient_dfn: "100")
        fhir = g.to_fhir
        assert_equal "Patient/100", fhir.dig(:subject, :reference)
      end

      # -- Validations (ported from rpms_redux) ----------------------------------

      test "validates patient_dfn presence" do
        g = Goal.new(description: "Health goal")
        assert_not g.valid?
        assert_includes g.errors[:patient_dfn], "can't be blank"
      end

      test "validates description presence" do
        g = Goal.new(patient_dfn: "1")
        assert_not g.valid?
        assert_includes g.errors[:description], "can't be blank"
      end

      test "validates lifecycle_status inclusion" do
        g = Goal.new(patient_dfn: "1", description: "Goal", lifecycle_status: "invalid")
        assert_not g.valid?
        assert_includes g.errors[:lifecycle_status], "is not included in the list"
      end

      test "allows valid lifecycle_status values" do
        %w[proposed planned accepted active on-hold completed cancelled entered-in-error rejected].each do |s|
          g = Goal.new(patient_dfn: "1", description: "Goal", lifecycle_status: s)
          assert g.valid?, "Expected #{s} to be valid"
        end
      end

      # -- FHIR extras (ported from rpms_redux) ----------------------------------

      test "to_fhir includes achievement status" do
        g = Goal.new(ien: "1", patient_dfn: "100", description: "Goal", achievement_status: "in-progress")
        fhir = g.to_fhir
        coding = fhir[:achievementStatus][:coding].first
        assert_equal "in-progress", coding[:code]
        assert_equal "http://terminology.hl7.org/CodeSystem/goal-achievement", coding[:system]
      end

      test "to_fhir includes start date" do
        g = Goal.new(ien: "1", patient_dfn: "100", description: "Goal", start_date: Date.new(2026, 1, 1))
        fhir = g.to_fhir
        assert_equal "2026-01-01", fhir[:startDate]
      end

      test "to_fhir includes target date" do
        g = Goal.new(ien: "1", patient_dfn: "100", description: "Goal", target_date: Date.new(2026, 6, 30))
        fhir = g.to_fhir
        assert_equal 1, fhir[:target].length
        assert_equal "2026-06-30", fhir[:target].first[:dueDate]
      end

      test "persisted? true when ien present" do
        assert Goal.new(ien: "1", patient_dfn: "1", description: "Goal").persisted?
      end

      test "persisted? false when ien blank" do
        refute Goal.new(patient_dfn: "1", description: "Goal").persisted?
      end
    end
  end
end
