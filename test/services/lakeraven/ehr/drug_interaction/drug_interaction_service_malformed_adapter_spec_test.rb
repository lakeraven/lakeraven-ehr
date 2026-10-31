# frozen_string_literal: true

require "test_helper"
require "ostruct"
require_relative "../../../../support/drug_interaction_adapter_test_helper"

module Lakeraven
  module EHR
    module DrugInteraction
      class DrugInteractionServiceMalformedAdapterSpecTest < ActiveSupport::TestCase
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

        test "adapter returning nil interaction entry yields incomplete fail-closed check" do
          adapter = build_malformed_adapter(check_interactions: ->(_) { [ nil ] })
          assert_incomplete_fail_closed(DrugInteractionService.new(adapter: adapter))
        end

        test "adapter returning string interaction entry yields incomplete fail-closed check" do
          adapter = build_malformed_adapter(check_interactions: ->(_) { [ "x" ] })
          assert_incomplete_fail_closed(DrugInteractionService.new(adapter: adapter))
        end

        test "adapter returning nil from check_allergies yields incomplete fail-closed check" do
          adapter = build_malformed_adapter(check_allergies: ->(_, _) { nil })
          assert_incomplete_fail_closed(DrugInteractionService.new(adapter: adapter))
        end

        private

        def build_malformed_adapter(check_interactions: ->(_) { [] }, check_allergies: ->(_, _) { [] })
          malformed = ::OpenStruct.new
          malformed.define_singleton_method(:backend) { :rpms }
          malformed.define_singleton_method(:check_interactions, &check_interactions)
          malformed.define_singleton_method(:check_allergies, &check_allergies)
          malformed
        end

        def assert_incomplete_fail_closed(service)
          result = service.check(
            active_medications: [ drug_interaction_med("warfarin", "11289") ],
            proposed_medication: drug_interaction_med("aspirin", "1191"),
            allergies: []
          )

          assert result.incomplete?
          refute result.safe?
          assert_empty result.interactions
          assert_nothing_raised { result.blocking? }
          refute result.blocking?
        end
      end
    end
  end
end
