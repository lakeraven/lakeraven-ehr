# frozen_string_literal: true

require "test_helper"
require "ostruct"
require_relative "../../../../support/drug_interaction_adapter_test_helper"

module Lakeraven
  module EHR
    module DrugInteraction
      class DrugInteractionServiceAdapterSpecTest < ActiveSupport::TestCase
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

        test "check accepts injected adapter and ignores factory backend selection" do
          null_adapter = ::OpenStruct.new
          null_adapter.define_singleton_method(:backend) { :iris }
          null_adapter.define_singleton_method(:check_interactions) { |_| [] }
          null_adapter.define_singleton_method(:check_allergies) { |_, _| [] }

          with_drug_interaction_backend_env(env_backend: "rpms") do
            service = DrugInteractionService.new(adapter: null_adapter)
            result = service.check(
              active_medications: [],
              proposed_medication: drug_interaction_med("acetaminophen", "161"),
              allergies: []
            )

            assert result.safe?
            assert_equal :iris, result.decision_source
          end
        end

        test "backend keyword selects adapter via AdapterFactory" do
          service = build_drug_interaction_service(backend: :mock)
          result = service.check(
            active_medications: [ drug_interaction_med("warfarin", "11289") ],
            proposed_medication: drug_interaction_med("aspirin", "1191"),
            allergies: []
          )

          assert result.blocking?
          assert_equal :mock, result.decision_source
        end

        test "decision_source follows the adapter backend" do
          service = build_drug_interaction_service(backend: :local)
          result = service.check(
            active_medications: [],
            proposed_medication: drug_interaction_med("acetaminophen", "161"),
            allergies: []
          )

          assert_equal :local, result.decision_source
        end

        test "unavailable backend returns incomplete fail-closed result with fixed reason" do
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
            assert_equal UNAVAILABLE_INCOMPLETE_REASON, result.incomplete_reason
            refute_match(/AdapterNotAvailable|UnavailableAdapter|NameError/i, result.incomplete_reason)
          end
        end

        test "non-unavailable adapter errors keep incomplete_reason from the exception" do
          failing_adapter = ::OpenStruct.new
          failing_adapter.define_singleton_method(:backend) { :local }
          failing_adapter.define_singleton_method(:check_interactions) { |_| raise "Connection refused" }
          failing_adapter.define_singleton_method(:check_allergies) { |_, _| [] }

          service = DrugInteractionService.new(adapter: failing_adapter)
          result = service.check(
            active_medications: [ drug_interaction_med("warfarin", "11289") ],
            proposed_medication: drug_interaction_med("aspirin", "1191"),
            allergies: []
          )

          assert result.incomplete?
          assert_includes result.incomplete_reason, "Connection refused"
        end

        test "registered builder that raises does not raise from DrugInteractionService.new" do
          drug_interaction_adapter_factory.register(:rpms) { raise "broker down" }
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
            assert_equal :rpms, result.decision_source
            assert_equal BUILDER_FAILURE_INCOMPLETE_REASON, result.incomplete_reason
            refute_includes result.incomplete_reason, "broker down"
          end
        end

        test "registered adapter missing check_allergies returns incomplete fail-closed result" do
          partial_adapter = Class.new(BaseAdapter) do
            define_method(:backend) { :rpms }
            define_method(:check_interactions) { |_| [] }
          end
          drug_interaction_adapter_factory.register(:rpms) { partial_adapter.new }

          service = build_drug_interaction_service(backend: :rpms)
          result = service.check(
            active_medications: [],
            proposed_medication: drug_interaction_med("acetaminophen", "161"),
            allergies: []
          )

          assert result.incomplete?
          refute result.safe?
        end

        test "adapter whose backend raises StandardError returns incomplete with unknown decision_source" do
          failing_adapter = ::OpenStruct.new
          failing_adapter.define_singleton_method(:backend) { raise StandardError, "backend metadata unavailable" }
          failing_adapter.define_singleton_method(:check_interactions) { |_| raise IOError, "RPC timeout for DFN 123" }
          failing_adapter.define_singleton_method(:check_allergies) { |_, _| [] }

          service = DrugInteractionService.new(adapter: failing_adapter)
          result = service.check(
            active_medications: [],
            proposed_medication: drug_interaction_med("acetaminophen", "161"),
            allergies: []
          )

          assert result.incomplete?
          assert_equal :unknown, result.decision_source
        end

        test "default service behaviour without ENV matches today's local YAML checks" do
          service = DrugInteractionService.new
          result = service.check(
            active_medications: [ drug_interaction_med("warfarin", "11289") ],
            proposed_medication: drug_interaction_med("aspirin", "1191"),
            allergies: []
          )

          refute result.safe?
          assert result.blocking?
          assert_equal :local, result.decision_source
          refute result.incomplete?
        end
      end
    end
  end
end
