# frozen_string_literal: true

require "test_helper"
require_relative "../../../../support/drug_interaction_adapter_test_helper"

module Lakeraven
  module EHR
    module DrugInteraction
      class YamlAdapterContractTest < ActiveSupport::TestCase
        include DrugInteractionAdapterTestHelper

        YAML_ADAPTER_CLASSES = [
          [ "LocalAdapter", :local ],
          [ "MockAdapter", :mock ]
        ].freeze

        YAML_ADAPTER_CLASSES.each do |class_name, backend|
          test "#{class_name} reports backend #{backend}" do
            adapter = adapter_class(class_name).new
            assert_respond_to adapter, :backend
            assert_equal backend, adapter.backend
          end

          test "#{class_name} detects warfarin and aspirin interaction" do
            adapter = adapter_class(class_name).new
            meds = [ drug_interaction_med("warfarin", "11289") ]
            proposed = drug_interaction_med("aspirin", "1191")

            alerts = adapter.check_interactions(meds + [ proposed ])
            assert alerts.any? { |a| a.severity == :high }
          end

          test "#{class_name} detects drug-allergy cross-reactivity" do
            adapter = adapter_class(class_name).new
            proposed = drug_interaction_med("amoxicillin", "723")
            allergies = [ drug_interaction_allergy("penicillin", "7984") ]

            alerts = adapter.check_allergies(proposed, allergies)
            assert alerts.any? { |a| a.interaction_type == :drug_allergy }
          end

          test "#{class_name} matches MockAdapter YAML alerts for shared scenarios" do
            reference = MockAdapter.new
            adapter = adapter_class(class_name).new
            active = [ drug_interaction_med("lisinopril", "29046") ]
            proposed = drug_interaction_med("potassium chloride", "8591")
            allergies = [ drug_interaction_allergy("penicillin", "7980") ]

            assert_same_yaml_interaction_alerts(
              reference, adapter,
              medications: active,
              proposed: proposed,
              allergies: allergies
            )
          end
        end

        test "LocalAdapter uses the default drug_interactions.yml knowledge base" do
          local_class = drug_interaction_adapter_class("LocalAdapter")
          assert_equal MockAdapter::KNOWLEDGE_BASE_PATH, local_class::KNOWLEDGE_BASE_PATH
        end

        private

        def adapter_class(class_name)
          class_name == "MockAdapter" ? MockAdapter : drug_interaction_adapter_class(class_name)
        end
      end
    end
  end
end
