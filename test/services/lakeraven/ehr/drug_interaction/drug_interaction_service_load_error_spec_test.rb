# frozen_string_literal: true

require "test_helper"
require "ostruct"
require_relative "../../../../support/drug_interaction_adapter_test_helper"

module Lakeraven
  module EHR
    module DrugInteraction
      class DrugInteractionServiceLoadErrorSpecTest < ActiveSupport::TestCase
        include DrugInteractionAdapterTestHelper

        setup do
          @original_backend_env = ENV["DRUG_INTERACTION_BACKEND"]
          @original_rails_env = Rails.env
          ENV["DRUG_INTERACTION_BACKEND"] = nil
          reset_drug_interaction_adapter_registrations!
        end

        teardown do
          ENV["DRUG_INTERACTION_BACKEND"] = @original_backend_env
          Rails.env = @original_rails_env
          reset_drug_interaction_adapter_registrations!
        end

        test "registered builder LoadError does not raise from DrugInteractionService.new" do
          drug_interaction_adapter_factory.register(:rpms) do
            raise LoadError, "cannot load such file -- synthetic_kb_client"
          end

          with_drug_interaction_backend_env(env_backend: "rpms") do
            service = assert_nothing_raised { DrugInteractionService.new }
            result = service.check(
              active_medications: [ drug_interaction_med("warfarin", "11289") ],
              proposed_medication: drug_interaction_med("aspirin", "1191"),
              allergies: []
            )

            assert result.incomplete?
            refute result.safe?
            assert_empty result.interactions
            assert_equal BUILDER_FAILURE_INCOMPLETE_REASON, result.incomplete_reason
            refute_includes result.incomplete_reason, "synthetic_kb_client"
          end
        end

        test "registered adapter check_interactions LoadError returns incomplete fail-closed check" do
          load_error_adapter = Class.new(BaseAdapter) do
            define_method(:backend) { :rpms }

            define_method(:check_interactions) do |_|
              raise LoadError, "cannot load such file -- synthetic_kb_client"
            end

            define_method(:check_allergies) { |_, _| [] }
          end
          drug_interaction_adapter_factory.register(:rpms) { load_error_adapter.new }

          with_drug_interaction_backend_env(env_backend: "rpms") do
            service = DrugInteractionService.new
            result = service.check(
              active_medications: [ drug_interaction_med("warfarin", "11289") ],
              proposed_medication: drug_interaction_med("aspirin", "1191"),
              allergies: []
            )

            assert result.incomplete?
            refute result.safe?
            assert_empty result.interactions
          end
        end
      end
    end
  end
end
