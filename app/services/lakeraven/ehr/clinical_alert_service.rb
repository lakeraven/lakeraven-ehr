# frozen_string_literal: true

module Lakeraven
  module EHR
    # Aggregates clinical alerts for a patient from multiple sources:
    # - Clinical reminders (DUE status only)
    # - Allergy alerts with severity
    #
    # Does NOT call DrugInteractionService — drug checks happen at prescribing time,
    # not on background page load.
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
          Alert.new(
            type: :allergy,
            description: a[:allergen] || a[:description],
            severity: map_allergy_severity(a[:severity])
          )
        end
      end

      def map_reminder_severity(reminder)
        case reminder[:priority]&.downcase
        when "high", "urgent" then :high
        when "moderate", "normal" then :moderate
        else :low
        end
      end

      def map_allergy_severity(severity)
        case severity&.downcase
        when "severe", "high" then :high
        when "moderate" then :moderate
        else :low
        end
      end
    end
  end
end
