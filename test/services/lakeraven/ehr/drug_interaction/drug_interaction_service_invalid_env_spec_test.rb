# frozen_string_literal: true

require "test_helper"
require "ostruct"
require_relative "../../../../support/drug_interaction_adapter_test_helper"

module Lakeraven
  module EHR
    module DrugInteraction
      class DrugInteractionServiceInvalidEnvSpecTest < ActiveSupport::TestCase
        include DrugInteractionAdapterTestHelper

        setup do
          @original_backend_env = ENV["DRUG_INTERACTION_BACKEND"]
          @original_rails_env = Rails.env
          reset_drug_interaction_adapter_registrations!
        end

        teardown do
          ENV["DRUG_INTERACTION_BACKEND"] = @original_backend_env
          Rails.env = @original_rails_env
          reset_drug_interaction_adapter_registrations!
        end

        test "invalid UTF-8 DRUG_INTERACTION_BACKEND does not break injected local adapter check" do
          local_adapter = drug_interaction_adapter_class("LocalAdapter").new

          with_synthetic_invalid_utf8_drug_interaction_backend_env do
            service = DrugInteractionService.new(adapter: local_adapter)
            result = service.check(
              active_medications: [ drug_interaction_med("warfarin", "11289") ],
              proposed_medication: drug_interaction_med("aspirin", "1191"),
              allergies: []
            )

            refute result.incomplete?
            refute result.safe?
            assert result.blocking?
            assert_equal :local, result.decision_source
            assert result.interactions.any?
          end
        end

        test "invalid UTF-8 DRUG_INTERACTION_BACKEND yields incomplete check with unknown decision_source" do
          with_synthetic_invalid_utf8_drug_interaction_backend_env do
            service = DrugInteractionService.new
            result = service.check(
              active_medications: [ drug_interaction_med("warfarin", "11289") ],
              proposed_medication: drug_interaction_med("aspirin", "1191"),
              allergies: []
            )

            assert result.incomplete?
            refute result.safe?
            assert_empty result.interactions
            assert_equal :unknown, result.decision_source
          end
        end
      end
    end
  end
end
