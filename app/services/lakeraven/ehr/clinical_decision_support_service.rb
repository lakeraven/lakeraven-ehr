# frozen_string_literal: true

require "ostruct"

module Lakeraven
  module EHR
    # ClinicalDecisionSupportService - ONC 170.315(a)(9)
    # HTI-1: Algorithm transparency requirements
    #
    # Aggregates CDS alerts from multiple sources:
    # 1. Drug interaction alerts (via DrugInteractionService)
    # 2. Clinical reminders
    # 3. Lab result interpretation
    # 4. Condition-based monitoring recommendations
    # 5. Demographics-based interventions (age, sex)
    # 6. Implantable device safety alerts
    class ClinicalDecisionSupportService
      CONFIG_PATH = Lakeraven::EHR::Engine.root.join("db/data/cds_rules.yml")

      def self.rules_config
        @rules_config ||= YAML.safe_load_file(CONFIG_PATH, permitted_classes: [ Symbol ]).deep_symbolize_keys
      end

      def self.reload_rules!
        @rules_config = nil
        rules_config
      end

      def self.rule_overrides
        @rule_overrides ||= {}
      end

      def self.rule_enabled?(rule_id)
        if rule_overrides.key?(rule_id.to_s)
          rule_overrides[rule_id.to_s]
        else
          rule = find_rule(rule_id)
          rule ? rule[:enabled] != false : true
        end
      end

      def self.update_rule_enabled(rule_id, enabled, provider_duz:)
        rule_overrides[rule_id.to_s] = enabled
        { rule_id: rule_id.to_s, enabled: enabled, updated_by: provider_duz, updated_at: Time.current }
      end

      def self.find_rule(rule_id)
        id = rule_id.to_s
        rules_config[:condition_rules]&.find { |r| r[:id] == id } ||
          rules_config[:demographic_rules]&.find { |r| r[:id] == id } ||
          rules_config[:device_rules]&.find { |r| r[:id] == id }
      end

      def self.all_rules
        [
          *(rules_config[:condition_rules] || []),
          *(rules_config[:demographic_rules] || []),
          *(rules_config[:device_rules] || [])
        ].map { |r| r.merge(enabled: rule_enabled?(r[:id])) }
      end

      class << self
        # Evaluate a proposed medication for CDS alerts
        def evaluate_medication(patient_dfn, proposed_drug)
          alerts = []

          proposed = OpenStruct.new(medication_display: proposed_drug, medication_code: nil)

          # Use the local knowledge base service for interaction checking
          service = DrugInteractionService.new
          active_meds = fetch_active_medications(patient_dfn)
          allergies = fetch_allergies(patient_dfn)

          result = service.check(
            active_medications: active_meds,
            proposed_medication: proposed,
            allergies: allergies
          )

          result.interactions.each do |interaction_alert|
            alerts << {
              id: "cds-di-#{SecureRandom.hex(4)}",
              category: "drug-interaction",
              severity: interaction_alert.severity.to_s,
              message: "#{interaction_alert.severity} interaction: #{interaction_alert.drug_a} + #{interaction_alert.drug_b} - #{interaction_alert.description}",
              recommendation: interaction_alert.description,
              source: "DrugInteractionService",
              evidence_level: "clinical-database",
              details: interaction_alert,
              created_at: Time.current
            }
          end

          CdsResult.new(patient_dfn: patient_dfn, alerts: alerts)
        end

        # Evaluate full patient context for CDS alerts
        def evaluate_patient(patient_dfn)
          alerts = []
          patient = Patient.find_by_dfn(patient_dfn)

          alerts.concat(evaluate_clinical_reminders)
          alerts.concat(evaluate_lab_results)
          alerts.concat(evaluate_conditions(patient))
          alerts.concat(evaluate_demographics(patient))
          alerts.concat(evaluate_devices(patient_dfn))

          CdsResult.new(patient_dfn: patient_dfn, alerts: alerts)
        end

        # Record an alert override
        def override_alert(alert:, provider_duz:, reason:)
          {
            alert_id: alert[:id],
            overridden: true,
            provider_duz: provider_duz,
            reason: reason,
            timestamp: Time.current,
            original_alert: alert
          }
        end

        # Stubbable data fetch methods
        def fetch_clinical_reminders
          []
        end

        def fetch_recent_labs
          []
        end

        private

        def fetch_active_medications(patient_dfn)
          MedicationRequest.for_patient(patient_dfn)
        rescue
          []
        end

        def fetch_allergies(patient_dfn)
          AllergyIntolerance.for_patient(patient_dfn)
        rescue
          []
        end

        def evaluate_clinical_reminders
          reminders = fetch_clinical_reminders
          return [] unless reminders.is_a?(Array)

          reminders.filter_map do |reminder|
            next unless reminder[:status] == "DUE"

            {
              id: "cds-rem-#{reminder[:ien] || SecureRandom.hex(4)}",
              category: "preventive-care",
              severity: "info",
              message: "#{reminder[:name]} is due",
              due_date: reminder[:due_date],
              last_done: reminder[:last_done],
              source: "Clinical Reminders",
              evidence_level: "clinical-guideline",
              created_at: Time.current
            }
          end
        end

        def evaluate_lab_results
          labs = fetch_recent_labs
          return [] unless labs.is_a?(Array)

          labs.filter_map do |lab|
            next if lab[:flag].blank?

            severity = lab[:flag]&.downcase == "critical" ? "critical" : "warning"

            {
              id: "cds-lab-#{lab[:ien] || SecureRandom.hex(4)}",
              category: "lab-result",
              severity: severity,
              message: "#{lab[:test_name]}: #{lab[:result]} #{lab[:units]} (reference high: #{lab[:reference_high]})",
              test_name: lab[:test_name],
              value: lab[:result],
              units: lab[:units],
              reference_high: lab[:reference_high],
              flag: lab[:flag],
              source: "Laboratory",
              evidence_level: "reference-range",
              created_at: Time.current
            }
          end
        end

        def evaluate_conditions(patient)
          conditions = patient&.problem_list
          return [] unless conditions.is_a?(Array)

          condition_rules = rules_config[:condition_rules] || []
          alerts = []

          conditions.each do |condition|
            next unless condition[:status]&.downcase == "active"

            description = condition[:description].to_s

            condition_rules.each do |rule|
              next unless rule_enabled?(rule[:id])
              next unless description.match?(Regexp.new(rule[:pattern], Regexp::IGNORECASE))

              alerts << {
                id: "cds-cond-#{condition[:ien] || SecureRandom.hex(4)}",
                category: "condition-based",
                rule_id: rule[:id],
                severity: rule[:severity] || "info",
                message: rule[:message],
                condition: description,
                monitoring: rule[:monitoring],
                source: rule[:source],
                source_url: rule[:source_url],
                evidence_level: rule[:evidence_level],
                created_at: Time.current
              }
            end
          end

          alerts
        end

        def evaluate_demographics(patient)
          return [] unless patient

          age = patient_age(patient)
          sex = patient.sex&.upcase

          demographic_rules = rules_config[:demographic_rules] || []
          alerts = []

          demographic_rules.each do |rule|
            next unless rule_enabled?(rule[:id])
            next unless demographic_match?(rule, age, sex)

            alerts << {
              id: "cds-demo-#{SecureRandom.hex(4)}",
              category: "demographic",
              rule_id: rule[:id],
              severity: rule[:severity] || "info",
              message: rule[:message],
              source: rule[:source],
              source_url: rule[:source_url],
              evidence_level: rule[:evidence_level],
              created_at: Time.current
            }
          end

          alerts
        end

        def patient_age(patient)
          return nil unless patient.dob.present?

          dob = patient.dob.is_a?(Date) ? patient.dob : Date.parse(patient.dob.to_s)
          today = Date.current
          age = today.year - dob.year
          age -= 1 if today < dob + age.years
          age
        rescue ArgumentError
          nil
        end

        def demographic_match?(rule, age, sex)
          return false if rule[:min_age] && (age.nil? || age < rule[:min_age])
          return false if rule[:max_age] && (age.nil? || age > rule[:max_age])
          return false if rule[:sex] && sex != rule[:sex]

          true
        end

        def evaluate_devices(patient_dfn)
          devices = Device.for_patient(patient_dfn)
          return [] unless devices.is_a?(Array) && devices.any?

          device_rules = rules_config[:device_rules] || []
          alerts = []

          devices.each do |device|
            device_type = (device.try(:device_name) || device.try(:type_display) || "").to_s
            device_code = (device.try(:type_code) || "").to_s

            device_rules.each do |rule|
              next unless rule_enabled?(rule[:id])
              next unless device_type_match?(rule, device_type, device_code)

              alerts << {
                id: "cds-dev-#{device.try(:ien) || SecureRandom.hex(4)}",
                category: "device",
                rule_id: rule[:id],
                severity: rule[:severity] || "warning",
                message: rule[:message],
                device: device_type,
                source: rule[:source],
                source_url: rule[:source_url],
                evidence_level: rule[:evidence_level],
                created_at: Time.current
              }
            end
          end

          alerts
        end

        def device_type_match?(rule, device_type, device_code)
          pattern = rule[:device_pattern]
          return false unless pattern

          device_type.match?(Regexp.new(pattern, Regexp::IGNORECASE)) ||
            device_code.match?(Regexp.new(pattern, Regexp::IGNORECASE))
        end
      end

      # Encapsulates CDS evaluation results
      class CdsResult
        attr_reader :patient_dfn, :alerts

        def initialize(patient_dfn:, alerts:)
          @patient_dfn = patient_dfn
          @alerts = alerts
        end

        def has_alerts?
          alerts.any?
        end

        def alerts_by_category(category)
          alerts.select { |a| a[:category] == category }
        end

        def critical_alerts
          alerts.select { |a| a[:severity] == "critical" }
        end

        def summary
          return "No clinical alerts" if alerts.empty?

          counts = alerts.group_by { |a| a[:category] }.transform_values(&:count)
          parts = counts.map { |cat, count| "#{count} #{cat}" }
          "#{alerts.count} alert(s): #{parts.join(', ')}"
        end

        def to_h
          {
            patient_dfn: patient_dfn,
            alerts: alerts,
            alert_count: alerts.count,
            summary: summary,
            evaluated_at: Time.current
          }
        end
      end
    end
  end
end
