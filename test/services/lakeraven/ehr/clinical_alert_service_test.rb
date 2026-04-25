# frozen_string_literal: true

require "test_helper"
require "ostruct"

module Lakeraven
  module EHR
    class ClinicalAlertServiceTest < ActiveSupport::TestCase
      setup do
        @patient_dfn = "99010"

        @test_reminders = [
          { name: "Influenza Vaccine", status: "DUE", priority: "high", due_date: Date.current },
          { name: "A1C Lab", status: "DUE", priority: nil, due_date: Date.current + 30 },
          { name: "Mammogram", status: "DONE", priority: nil }
        ]

        @test_allergies = [
          AllergyIntolerance.new(
            ien: "1", patient_dfn: @patient_dfn,
            allergen: "Penicillin", reaction: "Anaphylaxis",
            severity: "severe", clinical_status: "active", criticality: "high"
          ),
          AllergyIntolerance.new(
            ien: "2", patient_dfn: @patient_dfn,
            allergen: "Aspirin", reaction: "GI Upset",
            severity: "moderate", clinical_status: "active"
          ),
          AllergyIntolerance.new(
            ien: "3", patient_dfn: @patient_dfn,
            allergen: "Latex", reaction: "Rash",
            severity: "mild", clinical_status: "active", criticality: "low"
          )
        ]
      end

      # =============================================================================
      # BACKGROUND ALERTS
      # =============================================================================

      test "background_alerts returns reminders filtered to DUE status" do
        service = ClinicalAlertService.new(reminders: @test_reminders, allergies: [])
        result = service.background_alerts

        due_reminders = result.select { |a| a.type == :reminder }
        assert_equal 2, due_reminders.length
      end

      test "background_alerts returns allergy alerts" do
        service = ClinicalAlertService.new(reminders: [], allergies: @test_allergies)
        result = service.background_alerts

        allergy_alerts = result.select { |a| a.type == :allergy }
        assert_equal 3, allergy_alerts.length
      end

      test "background_alerts includes severity summary" do
        service = ClinicalAlertService.new(reminders: @test_reminders, allergies: @test_allergies)
        summary = service.severity_summary

        assert summary.key?(:high)
        assert summary.key?(:moderate)
        assert summary.key?(:low)
        total = summary.values.sum
        assert total > 0
      end

      test "background_alerts does NOT include drug interactions" do
        service = ClinicalAlertService.new(reminders: [], allergies: [])
        interactions = service.drug_interactions

        assert_equal [], interactions
      end

      test "background_alerts returns empty arrays with no data" do
        service = ClinicalAlertService.new(reminders: [], allergies: [])
        result = service.background_alerts

        assert_equal [], result
      end

      # =============================================================================
      # ALLERGY SEVERITY MAPPING
      # =============================================================================

      test "maps severe allergy to :high" do
        service = ClinicalAlertService.new(reminders: [], allergies: [
          AllergyIntolerance.new(allergen: "Test", severity: "severe", clinical_status: "active")
        ])
        alerts = service.background_alerts
        allergy_alert = alerts.find { |a| a.type == :allergy }
        assert_equal :high, allergy_alert.severity
      end

      test "maps moderate allergy to :moderate" do
        service = ClinicalAlertService.new(reminders: [], allergies: [
          AllergyIntolerance.new(allergen: "Test", severity: "moderate", clinical_status: "active")
        ])
        alerts = service.background_alerts
        allergy_alert = alerts.find { |a| a.type == :allergy }
        assert_equal :moderate, allergy_alert.severity
      end

      test "maps mild allergy to :low" do
        service = ClinicalAlertService.new(reminders: [], allergies: [
          AllergyIntolerance.new(allergen: "Test", severity: "mild", clinical_status: "active")
        ])
        alerts = service.background_alerts
        allergy_alert = alerts.find { |a| a.type == :allergy }
        assert_equal :low, allergy_alert.severity
      end

      test "defaults unknown severity to :moderate" do
        service = ClinicalAlertService.new(reminders: [], allergies: [
          AllergyIntolerance.new(allergen: "Test", severity: "unknown", clinical_status: "active")
        ])
        alerts = service.background_alerts
        allergy_alert = alerts.find { |a| a.type == :allergy }
        assert_equal :moderate, allergy_alert.severity
      end

      # =============================================================================
      # REMINDER SEVERITY MAPPING
      # =============================================================================

      test "maps high priority reminder to :high" do
        service = ClinicalAlertService.new(
          reminders: [ { name: "Test", status: "DUE", priority: "high" } ],
          allergies: []
        )
        alerts = service.background_alerts
        reminder = alerts.find { |a| a.type == :reminder }
        assert_equal :high, reminder.severity
      end

      test "maps nil priority DUE reminder to :moderate" do
        service = ClinicalAlertService.new(
          reminders: [ { name: "Test", status: "DUE", priority: nil } ],
          allergies: []
        )
        alerts = service.background_alerts
        reminder = alerts.find { |a| a.type == :reminder }
        assert_equal :moderate, reminder.severity
      end

      test "maps urgent priority reminder to :high" do
        service = ClinicalAlertService.new(
          reminders: [ { name: "Test", status: "DUE", priority: "urgent" } ],
          allergies: []
        )
        alerts = service.background_alerts
        reminder = alerts.find { |a| a.type == :reminder }
        assert_equal :high, reminder.severity
      end

      test "maps low priority reminder to :low" do
        service = ClinicalAlertService.new(
          reminders: [ { name: "Test", status: "DUE", priority: "low" } ],
          allergies: []
        )
        alerts = service.background_alerts
        reminder = alerts.find { |a| a.type == :reminder }
        assert_equal :low, reminder.severity
      end

      # =============================================================================
      # SEVERITY SUMMARY
      # =============================================================================

      test "severity_summary counts by severity level" do
        service = ClinicalAlertService.new(
          reminders: [ { name: "R1", status: "DUE", priority: "high" } ],
          allergies: [
            AllergyIntolerance.new(allergen: "A1", severity: "severe", clinical_status: "active"),
            AllergyIntolerance.new(allergen: "A2", severity: "mild", clinical_status: "active")
          ]
        )
        summary = service.severity_summary

        assert_equal 2, summary[:high]   # 1 reminder (high) + 1 allergy (severe->high)
        assert_equal 0, summary[:moderate]
        assert_equal 1, summary[:low]    # 1 allergy (mild->low)
      end

      # =============================================================================
      # ALERT STRUCT
      # =============================================================================

      test "Alert struct has type, description, severity" do
        alert = ClinicalAlertService::Alert.new(
          type: :reminder, description: "Flu Vaccine", severity: :high
        )
        assert_equal :reminder, alert.type
        assert_equal "Flu Vaccine", alert.description
        assert_equal :high, alert.severity
      end

      # =============================================================================
      # EDGE CASES
      # =============================================================================

      test "filters out non-DUE reminders" do
        reminders = [
          { name: "Done", status: "DONE", priority: nil },
          { name: "Due", status: "DUE", priority: nil }
        ]
        service = ClinicalAlertService.new(reminders: reminders, allergies: [])
        alerts = service.background_alerts

        assert_equal 1, alerts.length
        assert_equal "Due", alerts.first.description
      end
    end
  end
end
