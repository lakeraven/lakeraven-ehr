# frozen_string_literal: true

require "test_helper"
require_relative "../../../../support/drug_interaction_adapter_test_helper"

module Lakeraven
  module EHR
    module DrugInteraction
      class CpoeOrderResultIncompleteTest < ActiveSupport::TestCase
        include DrugInteractionAdapterTestHelper

        setup do
          # OrderResult lives in cpoe_service.rb and loads with CpoeService.
          Lakeraven::EHR::CpoeService
        end

        test "incomplete interaction_result sets has_interaction_alerts and interaction_check_incomplete" do
          incomplete = DrugInteractionResult.new(
            interactions: [],
            incomplete: true,
            incomplete_reason: BUILDER_FAILURE_INCOMPLETE_REASON,
            decision_source: :rpms
          )
          order = OpenStruct.new(status: "draft")
          result = Lakeraven::EHR::OrderResult.success(order, interaction_result: incomplete)

          assert result.has_interaction_alerts?
          assert result.interaction_check_incomplete?
          assert_empty result.interaction_alerts
        end

        test "complete interaction check with no interactions clears alert predicates" do
          complete = DrugInteractionResult.new(interactions: [], decision_source: :local)
          order = OpenStruct.new(status: "draft")
          result = Lakeraven::EHR::OrderResult.success(order, interaction_result: complete)

          refute result.has_interaction_alerts?
          refute result.interaction_check_incomplete?
          assert_empty result.interaction_alerts
        end

        test "complete interaction check with interactions keeps interaction_check_incomplete false" do
          alert = InteractionAlert.new(
            severity: :high, drug_a: "warfarin", drug_b: "aspirin", description: "Bleeding risk"
          )
          complete = DrugInteractionResult.new(interactions: [ alert ], decision_source: :local)
          order = OpenStruct.new(status: "draft")
          result = Lakeraven::EHR::OrderResult.success(order, interaction_result: complete)

          assert result.has_interaction_alerts?
          refute result.interaction_check_incomplete?
          assert_equal 1, result.interaction_alerts.length
        end
      end
    end
  end
end
