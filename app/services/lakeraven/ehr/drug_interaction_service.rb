# frozen_string_literal: true

require "yaml"

module Lakeraven
  module EHR
    # Orchestrates drug-drug and drug-allergy interaction checking.
    # ONC § 170.315(a)(4) compliance.
    #
    # Uses a local YAML knowledge base by default. Pluggable adapter
    # for RPMS pharmacy RPCs or external services.
    class DrugInteractionService
      KNOWLEDGE_BASE_PATH = File.expand_path("../../../../db/data/drug_interactions.yml", __dir__)

      def initialize
        kb = YAML.load_file(KNOWLEDGE_BASE_PATH)
        @class_members = kb["class_members"] || {}
        @drug_drug_rules = kb["drug_drug"] || []
        @drug_allergy_rules = kb["drug_allergy"] || []
      end

      def check(active_medications:, proposed_medication:, allergies:)
        all_meds = active_medications + [ proposed_medication ]

        interactions = []
        interactions.concat(check_drug_drug(all_meds))
        interactions.concat(check_drug_allergy(proposed_medication, allergies))

        DrugInteractionResult.new(interactions: interactions, decision_source: :local)
      end

      private

      def check_drug_drug(medications)
        return [] if medications.length < 2

        alerts = []
        medications.combination(2).each do |med_a, med_b|
          @drug_drug_rules.each do |rule|
            if pair_matches?(med_a, med_b, rule)
              alerts << InteractionAlert.new(
                severity: rule["severity"].to_sym,
                drug_a: med_a.medication_display,
                drug_b: med_b.medication_display,
                description: rule["description"],
                source: rule["source"]
              )
            end
          end
        end
        alerts
      end

      def check_drug_allergy(medication, allergies)
        med_allergies = allergies.select { |a| a.category&.downcase == "medication" }
        return [] if med_allergies.empty?

        alerts = []
        med_allergies.each do |allergy|
          @drug_allergy_rules.each do |rule|
            if allergy_matches?(medication, allergy, rule)
              alerts << InteractionAlert.new(
                severity: rule["severity"].to_sym,
                drug_a: medication.medication_display,
                drug_b: "#{allergy.allergen} allergy",
                description: rule["description"],
                source: rule["source"],
                interaction_type: :drug_allergy
              )
            end
          end
        end
        alerts
      end

      def pair_matches?(med_a, med_b, rule)
        (med_in_class?(med_a, rule["drug_a_class"]) && med_in_class?(med_b, rule["drug_b_class"])) ||
          (med_in_class?(med_a, rule["drug_b_class"]) && med_in_class?(med_b, rule["drug_a_class"]))
      end

      def allergy_matches?(medication, allergy, rule)
        allergy_in_class?(allergy, rule["allergen_class"]) && med_in_class?(medication, rule["drug_class"])
      end

      def med_in_class?(medication, class_name)
        members = @class_members[class_name]
        return false unless members

        codes = members["rxnorm"] || []
        names = members["names"] || []

        codes.include?(medication.medication_code.to_s) ||
          names.any? { |n| medication.medication_display&.downcase&.include?(n.downcase) }
      end

      def allergy_in_class?(allergy, class_name)
        members = @class_members[class_name]
        return false unless members

        codes = members["rxnorm"] || []
        names = members["names"] || []

        codes.include?(allergy.allergen_code.to_s) ||
          names.any? { |n| allergy.allergen&.downcase&.include?(n.downcase) }
      end
    end
  end
end
