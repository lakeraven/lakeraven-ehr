# frozen_string_literal: true

module Lakeraven
  module EHR
    # Aggregates clinical alerts for a patient from multiple sources:
    # - Clinical reminders (DUE status only)
    # - Allergy alerts with severity
    #
    # Does NOT call DrugInteractionService — drug checks happen at prescribing time,
    # not on background page load.
    #
    # Ported from rpms_redux ClinicalAlertService.
    class ClinicalAlertService
      Alert = Struct.new(:type, :description, :severity, keyword_init: true)

      def initialize(reminders: [], allergies: [])
        @reminders = reminders
        @allergies = allergies
      end

      def background_alerts
        alerts = []
        alerts.concat(reminder_alerts)
        alerts.concat(allergy_alerts)
        alerts
      end

      def severity_summary
        all = background_alerts
        {
          high: all.count { |a| a.severity == :high },
          moderate: all.count { |a| a.severity == :moderate },
          low: all.count { |a| a.severity == :low }
        }
      end

      def drug_interactions
        [] # Intentionally empty — drug checks at prescribing time only
      end

      private

      def reminder_alerts
        @reminders
          .select { |r| r[:status]&.upcase == "DUE" }
          .map do |r|
            Alert.new(
              type: :reminder,
              description: r[:name] || r[:description],
              severity: map_reminder_severity(r)
            )
          end
      end

      def allergy_alerts
        @allergies.map do |a|
          allergen = a.respond_to?(:allergen) ? a.allergen : a[:allergen]
          severity_val = a.respond_to?(:severity) ? a.severity : a[:severity]
          criticality_val = a.respond_to?(:criticality) ? a.criticality : a[:criticality]

          Alert.new(
            type: :allergy,
            description: allergen || (a.respond_to?(:description) ? a.description : a[:description]),
            severity: map_allergy_severity(severity_val, criticality: criticality_val)
          )
        end
      end

      def map_reminder_severity(reminder)
        case reminder[:priority]&.downcase
        when "high", "urgent" then :high
        when "low" then :low
        else :moderate # DUE status defaults to moderate
        end
      end

      def map_allergy_severity(severity, criticality: nil)
        if severity.present?
          case severity.downcase
          when "severe", "high" then :high
          when "moderate" then :moderate
          when "mild", "low" then :low
          else criticality_fallback(criticality)
          end
        else
          criticality_fallback(criticality)
        end
      end

      def criticality_fallback(criticality)
        case criticality&.downcase
        when "high" then :high
        when "low", "unable-to-assess" then :low
        else :moderate
        end
      end
    end
  end
end
