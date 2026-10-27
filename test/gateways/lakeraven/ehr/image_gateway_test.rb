# frozen_string_literal: true

require "test_helper"

# Tests for ImageGateway — imaging-study list.
# Wraps RpmsRpc::Image (lakeraven/rpms-rpc#75).
module Lakeraven
  module EHR
    class ImageGatewayTest < ActiveSupport::TestCase
      class FakeImageAPI
        attr_reader :calls

        def initialize(returns: {})
          @returns = returns
          @calls = []
        end

        def exams_for_patient(dfn)
          @calls << { method: :exams_for_patient, args: [ dfn ] }
          @returns[:exams_for_patient] || []
        end
      end

      # --- via: nil ---

      test "exams_for_patient returns empty when no provider is available" do
        assert_equal [], ImageGateway.exams_for_patient(1, via: nil)
      end

      # --- delegation + coercion ---

      test "exams_for_patient delegates with dfn coerced to a string" do
        exams = [ { ien: 1, modality: "CT" } ]
        fake = FakeImageAPI.new(returns: { exams_for_patient: exams })

        assert_equal exams, ImageGateway.exams_for_patient(1, via: fake)
        assert_equal [ "1" ], fake.calls.first[:args]
      end

      # --- default_provider ---

      test "default_provider resolves to RpmsRpc::Image when the gem ships it" do
        provider = ImageGateway.default_provider
        refute_nil provider, "expected RpmsRpc::Image to be loaded via the gateway's guarded require"
        assert_equal "RpmsRpc::Image", provider.name
      end
    end
  end
end
