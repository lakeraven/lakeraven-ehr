# frozen_string_literal: true

require "test_helper"

# Tests for SymptomGateway — allergy-symptom catalog lookup for the
# order-entry allergy-precheck UI.
# Wraps RpmsRpc::Symptom (lakeraven/rpms-rpc#73).
module Lakeraven
  module EHR
    class SymptomGatewayTest < ActiveSupport::TestCase
      class FakeSymptomAPI
        attr_reader :calls

        def initialize(returns: {})
          @returns = returns
          @calls = []
        end

        def search(query)
          @calls << { method: :search, args: [ query ] }
          @returns[:search] || []
        end

        def defaults
          @calls << { method: :defaults, args: [] }
          @returns[:defaults] || []
        end
      end

      # --- via: nil ---

      test "search returns empty when no provider is available" do
        assert_equal [], SymptomGateway.search("rash", via: nil)
      end

      test "defaults returns empty when no provider is available" do
        assert_equal [], SymptomGateway.defaults(via: nil)
      end

      # --- delegation ---

      test "search delegates with the query coerced to a string" do
        list = [ { ien: 1, name: "Rash" } ]
        fake = FakeSymptomAPI.new(returns: { search: list })

        assert_equal list, SymptomGateway.search(:rash, via: fake)
        assert_equal [ "rash" ], fake.calls.first[:args]
      end

      test "defaults delegates without arguments" do
        list = [ { ien: 1, name: "Anaphylaxis" } ]
        fake = FakeSymptomAPI.new(returns: { defaults: list })

        assert_equal list, SymptomGateway.defaults(via: fake)
      end

      # --- default_provider ---

      test "default_provider resolves to RpmsRpc::Symptom when the gem ships it" do
        provider = SymptomGateway.default_provider
        refute_nil provider, "expected RpmsRpc::Symptom to be loaded via the gateway's guarded require"
        assert_equal "RpmsRpc::Symptom", provider.name
      end
    end
  end
end
