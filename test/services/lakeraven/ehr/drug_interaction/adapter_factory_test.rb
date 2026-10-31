# frozen_string_literal: true

require "test_helper"
require_relative "../../../../support/drug_interaction_adapter_test_helper"

module Lakeraven
  module EHR
    module DrugInteraction
      class DrugInteractionAdapterFactoryTest < ActiveSupport::TestCase
        include DrugInteractionAdapterTestHelper

        DOCUMENTED_BACKENDS = %i[local mock rpms iris fass fdb].freeze
        PLACEHOLDER_BACKENDS = %i[rpms iris fass fdb].freeze

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

        test "build with no argument defaults to local backend" do
          adapter = drug_interaction_adapter_factory.build
          assert_equal :local, adapter.backend
          assert_kind_of drug_interaction_adapter_class("LocalAdapter"), adapter
        end

        test "DRUG_INTERACTION_BACKEND is stripped and downcased" do
          ENV["DRUG_INTERACTION_BACKEND"] = " LOCAL "
          adapter = drug_interaction_adapter_factory.build
          assert_kind_of drug_interaction_adapter_class("LocalAdapter"), adapter
          assert_equal :local, adapter.backend

          ENV["DRUG_INTERACTION_BACKEND"] = " Mock "
          adapter = drug_interaction_adapter_factory.build
          assert_equal :mock, adapter.backend
          assert_kind_of MockAdapter, adapter
        end

        test "builds MockAdapter for mock backend outside production" do
          Rails.env = "test"
          adapter = drug_interaction_adapter_factory.build(:mock)
          assert_equal :mock, adapter.backend
          assert_kind_of MockAdapter, adapter
        end

        test "explicit mock backend is refused in production" do
          Rails.env = "production"
          error = assert_raises(ArgumentError) { drug_interaction_adapter_factory.build(:mock) }
          assert_match(/production/i, error.message)
        end

        test "DRUG_INTERACTION_BACKEND mock in production builds unavailable adapter" do
          Rails.env = "production"
          ENV["DRUG_INTERACTION_BACKEND"] = "mock"
          adapter = assert_nothing_raised { drug_interaction_adapter_factory.build }
          assert_equal :mock, adapter.backend
          assert_raises(drug_interaction_adapter_not_available) { adapter.check_interactions([]) }
        end

        PLACEHOLDER_BACKENDS.each do |backend|
          test "unregistered #{backend} backend builds without error and raises AdapterNotAvailable on use" do
            adapter = drug_interaction_adapter_factory.build(backend)
            assert_equal backend, adapter.backend
            error = assert_raises(drug_interaction_adapter_not_available) do
              adapter.check_interactions([
                drug_interaction_med("warfarin", "11289"),
                drug_interaction_med("aspirin", "1191")
              ])
            end
            assert_match(/#{backend}/i, error.message)
          end
        end

        test "configured unknown DRUG_INTERACTION_BACKEND builds an unavailable adapter" do
          ENV["DRUG_INTERACTION_BACKEND"] = "bogus"
          adapter = drug_interaction_adapter_factory.build
          assert_equal :bogus, adapter.backend
          error = assert_raises(drug_interaction_adapter_not_available) { adapter.check_allergies(drug_interaction_med("a", "1"), []) }
          assert_match(/bogus/i, error.message)
        end

        test "explicit unknown backend argument raises ArgumentError listing available backends" do
          error = assert_raises(ArgumentError) { drug_interaction_adapter_factory.build(:nonsense) }
          assert_match(/nonsense/i, error.message)
          DOCUMENTED_BACKENDS.each do |name|
            assert_match(/#{name}/i, error.message)
          end
        end

        test "non-name backend argument raises ArgumentError" do
          assert_raises(ArgumentError) { drug_interaction_adapter_factory.build(123) }
          assert_raises(ArgumentError) { drug_interaction_adapter_factory.build(Object.new) }
        end

        test "register without a block raises ArgumentError at registration time" do
          assert_raises(ArgumentError) { drug_interaction_adapter_factory.register(:rpms) }
        end

        test "register returns a custom adapter for the registered backend" do
          sentinel = Class.new(BaseAdapter) do
            define_method(:backend) { :rpms }
            define_method(:check_interactions) { |_meds| [] }
            define_method(:check_allergies) { |_, _| [] }
          end

          drug_interaction_adapter_factory.register(:rpms) { sentinel.new }
          adapter = drug_interaction_adapter_factory.build(:rpms)
          assert_equal :rpms, adapter.backend
          assert_empty adapter.check_interactions([])
        end

        test "reset_registrations clears host registrations" do
          drug_interaction_adapter_factory.register(:rpms) { drug_interaction_adapter_class("LocalAdapter").new }
          drug_interaction_adapter_factory.reset_registrations!
          adapter = drug_interaction_adapter_factory.build(:rpms)
          assert_raises(drug_interaction_adapter_not_available) { adapter.check_interactions([]) }
        end

        test "build rejects a registration that does not return a BaseAdapter" do
          drug_interaction_adapter_factory.register(:rpms) { Object.new }
          assert_raises(ArgumentError) { drug_interaction_adapter_factory.build(:rpms) }

          drug_interaction_adapter_factory.reset_registrations!
          drug_interaction_adapter_factory.register(:rpms) { "not-an-adapter" }
          assert_raises(ArgumentError) { drug_interaction_adapter_factory.build(:rpms) }
        end

        test "build rejects a registration whose adapter backend differs from the registered name" do
          drug_interaction_adapter_factory.register(:rpms) { drug_interaction_adapter_class("LocalAdapter").new }
          error = assert_raises(ArgumentError) { drug_interaction_adapter_factory.build(:rpms) }
          assert_match(/rpms/i, error.message)
          assert_match(/local/i, error.message)
        end

        test "build rejects registration that returns bare BaseAdapter without implemented backend" do
          drug_interaction_adapter_factory.register(:rpms) { BaseAdapter.new }
          error = assert_raises(ArgumentError) { drug_interaction_adapter_factory.build(:rpms) }
          assert_match(/rpms/i, error.message)
          refute_kind_of NotImplementedError, error.class
        end

        test "building every documented backend does not raise NameError" do
          Rails.env = "test"
          DOCUMENTED_BACKENDS.each do |backend|
            assert_nothing_raised do
              adapter = drug_interaction_adapter_factory.build(backend)
              assert_kind_of BaseAdapter, adapter
              assert_equal backend, adapter.backend
              %i[check_interactions check_allergies backend].each do |method|
                assert_respond_to adapter, method
              end
            end
          end
        end

        test "AdapterNotAvailable is a StandardError" do
          assert_operator drug_interaction_adapter_not_available, :<=, StandardError
        end
      end
    end
  end
end
