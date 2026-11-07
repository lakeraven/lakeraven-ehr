# frozen_string_literal: true

require "test_helper"
require_relative "../support/drug_interaction_adapter_test_helper"

class GlobalStoreIsolationAdapterFactoryTest < ActiveSupport::TestCase
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

  test "GlobalStoreIsolation.reset! clears host DrugInteraction adapter registrations" do
    sentinel = Class.new(Lakeraven::EHR::DrugInteraction::BaseAdapter) do
      define_method(:backend) { :rpms }
      define_method(:check_interactions) { |_| [] }
      define_method(:check_allergies) { |_, _| [] }
    end

    drug_interaction_adapter_factory.register(:rpms) { sentinel.new }
    assert_nothing_raised { drug_interaction_adapter_factory.build(:rpms) }

    GlobalStoreIsolation.reset!

    adapter = drug_interaction_adapter_factory.build(:rpms)
    assert_raises(drug_interaction_adapter_not_available) { adapter.check_interactions([]) }
  end
end
