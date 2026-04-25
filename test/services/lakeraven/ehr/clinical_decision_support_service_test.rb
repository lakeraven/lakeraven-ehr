# frozen_string_literal: true

require "test_helper"
require "ostruct"

module Lakeraven
  module EHR
    class ClinicalDecisionSupportServiceTest < ActiveSupport::TestCase
      setup do
        @_orig_patient_find = Patient.method(:find_by_dfn)
        @_orig_med_for_patient = MedicationRequest.method(:for_patient)
        @_orig_allergy_for_patient = AllergyIntolerance.method(:for_patient)
        @_orig_device_for_patient = Device.method(:for_patient)

        # Default mocks: empty data
        mock_no_medications("12345")
        mock_no_allergies("12345")
        mock_no_devices("12345")
        mock_no_conditions("12345")

        ClinicalDecisionSupportService.reload_rules!
        ClinicalDecisionSupportService.rule_overrides.clear
      end

      teardown do
        Patient.define_singleton_method(:find_by_dfn, @_orig_patient_find)
        MedicationRequest.define_singleton_method(:for_patient, @_orig_med_for_patient)
        AllergyIntolerance.define_singleton_method(:for_patient, @_orig_allergy_for_patient)
        Device.define_singleton_method(:for_patient, @_orig_device_for_patient)

        ClinicalDecisionSupportService.reload_rules!
        ClinicalDecisionSupportService.rule_overrides.clear
      end

      # =============================================================================
      # DRUG INTERACTION ALERTS
      # =============================================================================

      test "returns drug interaction alert for proposed medication" do
        mock_active_medications("12345", [
          { drug_name: "Warfarin 5mg", rxnorm_code: "11289", status: "active" }
        ])

        result = ClinicalDecisionSupportService.evaluate_medication("12345", "Ibuprofen 400mg")

        assert result.has_alerts?
        drug_alerts = result.alerts_by_category("drug-interaction")
        assert_not_empty drug_alerts
      end

      test "no drug alerts for safe medication" do
        result = ClinicalDecisionSupportService.evaluate_medication("12345", "Lisinopril 10mg")

        drug_alerts = result.alerts_by_category("drug-interaction")
        assert_empty drug_alerts
      end

      # =============================================================================
      # CLINICAL REMINDERS
      # =============================================================================

      test "returns preventive care alerts for overdue reminders" do
        reminders = [
          { ien: "1", name: "Influenza Vaccine", status: "DUE", due_date: 1.month.ago.to_date },
          { ien: "2", name: "Colorectal Cancer Screening", status: "DUE", due_date: 3.months.ago.to_date }
        ]

        ClinicalDecisionSupportService.define_singleton_method(:fetch_clinical_reminders) { reminders }
        ClinicalDecisionSupportService.define_singleton_method(:fetch_recent_labs) { [] }

        result = ClinicalDecisionSupportService.evaluate_patient("12345")

        reminder_alerts = result.alerts_by_category("preventive-care")
        assert_equal 2, reminder_alerts.length
        assert_includes reminder_alerts.first[:message], "Influenza Vaccine"
      end

      test "no preventive alerts when reminders are current" do
        reminders = [
          { ien: "1", name: "Influenza Vaccine", status: "DONE", last_done: 2.months.ago.to_date }
        ]

        ClinicalDecisionSupportService.define_singleton_method(:fetch_clinical_reminders) { reminders }
        ClinicalDecisionSupportService.define_singleton_method(:fetch_recent_labs) { [] }

        result = ClinicalDecisionSupportService.evaluate_patient("12345")

        reminder_alerts = result.alerts_by_category("preventive-care")
        assert_empty reminder_alerts
      end

      # =============================================================================
      # LAB RESULT INTERPRETATION
      # =============================================================================

      test "alerts on critical lab values" do
        labs = [
          { ien: "1", test_name: "Potassium", result: "6.2", units: "mEq/L",
            reference_high: "5.0", flag: "critical" }
        ]

        ClinicalDecisionSupportService.define_singleton_method(:fetch_clinical_reminders) { [] }
        ClinicalDecisionSupportService.define_singleton_method(:fetch_recent_labs) { labs }

        result = ClinicalDecisionSupportService.evaluate_patient("12345")

        lab_alerts = result.alerts_by_category("lab-result")
        assert_not_empty lab_alerts
        assert_equal "critical", lab_alerts.first[:severity]
        assert_includes lab_alerts.first[:message], "Potassium"
      end

      test "no lab alerts for normal values" do
        labs = [
          { ien: "1", test_name: "Sodium", result: "140", units: "mEq/L",
            reference_high: "145", flag: nil }
        ]

        ClinicalDecisionSupportService.define_singleton_method(:fetch_clinical_reminders) { [] }
        ClinicalDecisionSupportService.define_singleton_method(:fetch_recent_labs) { labs }

        result = ClinicalDecisionSupportService.evaluate_patient("12345")

        lab_alerts = result.alerts_by_category("lab-result")
        assert_empty lab_alerts
      end

      # =============================================================================
      # CONDITION-BASED ALERTS
      # =============================================================================

      test "suggests monitoring for diabetic patient" do
        mock_conditions("12345", [
          { ien: "1", description: "Diabetes mellitus type 2", icd10: "E11.9", status: "active" }
        ])

        ClinicalDecisionSupportService.define_singleton_method(:fetch_clinical_reminders) { [] }
        ClinicalDecisionSupportService.define_singleton_method(:fetch_recent_labs) { [] }

        result = ClinicalDecisionSupportService.evaluate_patient("12345")

        condition_alerts = result.alerts_by_category("condition-based")
        assert_not_empty condition_alerts
        assert_includes condition_alerts.first[:message].downcase, "diabetes"
      end

      # =============================================================================
      # ALGORITHM TRANSPARENCY (HTI-1)
      # =============================================================================

      test "alerts include source attribution" do
        mock_active_medications("12345", [
          { drug_name: "Warfarin 5mg", rxnorm_code: "11289", status: "active" }
        ])

        result = ClinicalDecisionSupportService.evaluate_medication("12345", "Ibuprofen 400mg")

        result.alerts.each do |alert|
          assert alert.key?(:source), "Alert should include source reference"
          assert alert.key?(:evidence_level), "Alert should include evidence level"
        end
      end

      # =============================================================================
      # ALERT OVERRIDE
      # =============================================================================

      test "records alert override with reason" do
        alert = {
          id: "alert-1", category: "drug-interaction",
          severity: "severe", message: "Warfarin + Ibuprofen interaction"
        }

        override = ClinicalDecisionSupportService.override_alert(
          alert: alert, provider_duz: "789",
          reason: "Clinical judgement - benefit outweighs risk"
        )

        assert override[:overridden]
        assert_equal "789", override[:provider_duz]
        assert_equal "Clinical judgement - benefit outweighs risk", override[:reason]
        assert override[:timestamp].present?
      end

      # =============================================================================
      # CDS RESULT
      # =============================================================================

      test "result summary lists alert counts" do
        result = ClinicalDecisionSupportService::CdsResult.new(patient_dfn: "12345", alerts: [])
        assert_equal "No clinical alerts", result.summary
      end

      test "result to_h serializes correctly" do
        result = ClinicalDecisionSupportService::CdsResult.new(patient_dfn: "12345", alerts: [])
        hash = result.to_h
        assert_equal "12345", hash[:patient_dfn]
        assert hash.key?(:alerts)
        assert hash.key?(:summary)
        assert hash.key?(:evaluated_at)
      end

      # =============================================================================
      # DEMOGRAPHICS-BASED ALERTS
      # =============================================================================

      test "alerts on elderly patient for fall risk" do
        mock_patient_with_demographics("12345", dob: 70.years.ago.to_date, sex: "M")
        ClinicalDecisionSupportService.define_singleton_method(:fetch_clinical_reminders) { [] }
        ClinicalDecisionSupportService.define_singleton_method(:fetch_recent_labs) { [] }

        result = ClinicalDecisionSupportService.evaluate_patient("12345")

        demo_alerts = result.alerts_by_category("demographic")
        assert demo_alerts.any?, "Expected demographic alerts for 70-year-old male"
        messages = demo_alerts.map { |a| a[:message] }.join(" ")
        assert_match(/fall risk/i, messages)
      end

      test "alerts on female patient for cervical cancer screening" do
        mock_patient_with_demographics("12345", dob: 35.years.ago.to_date, sex: "F")
        ClinicalDecisionSupportService.define_singleton_method(:fetch_clinical_reminders) { [] }
        ClinicalDecisionSupportService.define_singleton_method(:fetch_recent_labs) { [] }

        result = ClinicalDecisionSupportService.evaluate_patient("12345")

        demo_alerts = result.alerts_by_category("demographic")
        messages = demo_alerts.map { |a| a[:message] }.join(" ")
        assert_match(/cervical/i, messages)
      end

      test "no demographic alerts for young male without matching rules" do
        mock_patient_with_demographics("12345", dob: 30.years.ago.to_date, sex: "M")
        ClinicalDecisionSupportService.define_singleton_method(:fetch_clinical_reminders) { [] }
        ClinicalDecisionSupportService.define_singleton_method(:fetch_recent_labs) { [] }

        result = ClinicalDecisionSupportService.evaluate_patient("12345")

        demo_alerts = result.alerts_by_category("demographic")
        assert_empty demo_alerts
      end

      test "pediatric lead screening for child under 6" do
        mock_patient_with_demographics("12345", dob: 3.years.ago.to_date, sex: "M")
        ClinicalDecisionSupportService.define_singleton_method(:fetch_clinical_reminders) { [] }
        ClinicalDecisionSupportService.define_singleton_method(:fetch_recent_labs) { [] }

        result = ClinicalDecisionSupportService.evaluate_patient("12345")

        demo_alerts = result.alerts_by_category("demographic")
        messages = demo_alerts.map { |a| a[:message] }.join(" ")
        assert_match(/lead/i, messages)
      end

      # =============================================================================
      # DEVICE-BASED ALERTS
      # =============================================================================

      test "alerts on patient with pacemaker" do
        mock_patient_with_demographics("12345", dob: 70.years.ago.to_date, sex: "M")
        mock_devices("12345", [
          OpenStruct.new(ien: "1", device_name: "Cardiac pacemaker dual-chamber",
                         type_code: "14106009", type_display: "Cardiac pacemaker")
        ])
        ClinicalDecisionSupportService.define_singleton_method(:fetch_clinical_reminders) { [] }
        ClinicalDecisionSupportService.define_singleton_method(:fetch_recent_labs) { [] }

        result = ClinicalDecisionSupportService.evaluate_patient("12345")

        device_alerts = result.alerts_by_category("device")
        assert device_alerts.any?, "Expected device alerts for pacemaker patient"
        messages = device_alerts.map { |a| a[:message] }.join(" ")
        assert_match(/MRI/i, messages)
      end

      test "alerts on patient with joint prosthesis" do
        mock_patient_with_demographics("12345", dob: 65.years.ago.to_date, sex: "F")
        mock_devices("12345", [
          OpenStruct.new(ien: "2", device_name: "Total knee replacement prosthesis",
                         type_code: "304120007", type_display: "Joint prosthesis")
        ])
        ClinicalDecisionSupportService.define_singleton_method(:fetch_clinical_reminders) { [] }
        ClinicalDecisionSupportService.define_singleton_method(:fetch_recent_labs) { [] }

        result = ClinicalDecisionSupportService.evaluate_patient("12345")

        device_alerts = result.alerts_by_category("device")
        messages = device_alerts.map { |a| a[:message] }.join(" ")
        assert_match(/antibiotic prophylaxis/i, messages)
      end

      test "no device alerts when patient has no devices" do
        mock_patient_with_demographics("12345", dob: 50.years.ago.to_date, sex: "M")
        ClinicalDecisionSupportService.define_singleton_method(:fetch_clinical_reminders) { [] }
        ClinicalDecisionSupportService.define_singleton_method(:fetch_recent_labs) { [] }

        result = ClinicalDecisionSupportService.evaluate_patient("12345")

        device_alerts = result.alerts_by_category("device")
        assert_empty device_alerts
      end

      # =============================================================================
      # PROVIDER CONFIGURABILITY
      # =============================================================================

      test "provider can disable a CDS rule" do
        ClinicalDecisionSupportService.update_rule_enabled("fall_risk_elderly", false, provider_duz: "789")
        refute ClinicalDecisionSupportService.rule_enabled?("fall_risk_elderly")
      end

      test "provider can re-enable a disabled rule" do
        ClinicalDecisionSupportService.update_rule_enabled("fall_risk_elderly", false, provider_duz: "789")
        change = ClinicalDecisionSupportService.update_rule_enabled("fall_risk_elderly", true, provider_duz: "789")
        assert_equal true, change[:enabled]
        assert ClinicalDecisionSupportService.rule_enabled?("fall_risk_elderly")
      end

      test "all_rules returns rules with current enabled state" do
        rules = ClinicalDecisionSupportService.all_rules
        assert rules.any?, "Expected rules to be loaded"
        rules.each do |rule|
          assert rule[:id].present?, "Each rule should have an id"
          assert [ true, false ].include?(rule[:enabled]), "Each rule should have enabled state"
        end
      end

      # =============================================================================
      # BIBLIOGRAPHIC CITATIONS
      # =============================================================================

      test "condition alerts include source URL" do
        mock_conditions("12345", [
          { ien: "1", description: "Diabetes mellitus type 2", icd10: "E11.9", status: "active" }
        ])
        ClinicalDecisionSupportService.define_singleton_method(:fetch_clinical_reminders) { [] }
        ClinicalDecisionSupportService.define_singleton_method(:fetch_recent_labs) { [] }

        result = ClinicalDecisionSupportService.evaluate_patient("12345")

        condition_alerts = result.alerts_by_category("condition-based")
        assert condition_alerts.any?
        condition_alerts.each do |alert|
          assert alert[:source].present?, "Expected source on condition alert"
          assert alert[:source_url].present?, "Expected source_url on condition alert"
        end
      end

      test "demographic alerts include source URL" do
        mock_patient_with_demographics("12345", dob: 70.years.ago.to_date, sex: "M")
        ClinicalDecisionSupportService.define_singleton_method(:fetch_clinical_reminders) { [] }
        ClinicalDecisionSupportService.define_singleton_method(:fetch_recent_labs) { [] }

        result = ClinicalDecisionSupportService.evaluate_patient("12345")

        demo_alerts = result.alerts_by_category("demographic")
        assert demo_alerts.any?
        demo_alerts.each do |alert|
          assert alert[:source_url].present?, "Expected source_url on demographic alert"
        end
      end

      private

      def mock_patient_with_demographics(dfn, dob:, sex:)
        Patient.define_singleton_method(:find_by_dfn) do |patient_dfn|
          if patient_dfn.to_s == dfn.to_s
            patient = Patient.new(dfn: patient_dfn.to_i, name: "TEST,PATIENT", sex: sex, dob: dob)
            patient.define_singleton_method(:problem_list) { [] }
            patient
          end
        end
      end

      def mock_devices(dfn, devices)
        Device.define_singleton_method(:for_patient) do |patient_dfn, **_opts|
          patient_dfn.to_s == dfn.to_s ? devices : []
        end
      end

      def mock_no_devices(dfn)
        mock_devices(dfn, [])
      end

      def mock_active_medications(dfn, meds)
        med_objects = meds.map do |m|
          OpenStruct.new(
            medication_display: m[:drug_name],
            medication_code: m[:rxnorm_code],
            status: m[:status]
          )
        end
        MedicationRequest.define_singleton_method(:for_patient) do |patient_dfn, **_opts|
          patient_dfn.to_s == dfn.to_s ? med_objects : []
        end
      end

      def mock_no_medications(dfn)
        mock_active_medications(dfn, [])
      end

      def mock_no_allergies(dfn)
        AllergyIntolerance.define_singleton_method(:for_patient) do |patient_dfn|
          patient_dfn.to_s == dfn.to_s ? [] : []
        end
      end

      def mock_conditions(dfn, conditions)
        Patient.define_singleton_method(:find_by_dfn) do |patient_dfn|
          if patient_dfn.to_s == dfn.to_s
            patient = Patient.new(dfn: patient_dfn.to_i, name: "TEST,PATIENT", sex: "M", dob: 50.years.ago.to_date)
            patient.define_singleton_method(:problem_list) { conditions }
            patient
          end
        end
      end

      def mock_no_conditions(dfn)
        mock_conditions(dfn, [])
      end
    end
  end
end
