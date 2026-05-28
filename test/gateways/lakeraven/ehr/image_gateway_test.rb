# frozen_string_literal: true

require "test_helper"

# Tests for ImageGateway — imaging-study list and viewer-launch handoff.
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

        def launch_token(dfn, study_ien, ttl_seconds: 300)
          @calls << { method: :launch_token, args: [ dfn, study_ien ], ttl_seconds: ttl_seconds }
          @returns[:launch_token]
        end
      end

      # --- via: nil ---

      test "exams_for_patient returns empty when no provider is available" do
        assert_equal [], ImageGateway.exams_for_patient(1, via: nil)
      end

      test "launch_token returns nil when no provider is available" do
        assert_nil ImageGateway.launch_token(1, 555, via: nil)
      end

      # --- delegation + coercion ---

      test "exams_for_patient delegates with dfn coerced to a string" do
        exams = [ { ien: 1, modality: "CT" } ]
        fake = FakeImageAPI.new(returns: { exams_for_patient: exams })

        assert_equal exams, ImageGateway.exams_for_patient(1, via: fake)
        assert_equal [ "1" ], fake.calls.first[:args]
      end

      test "launch_token delegates identifiers as strings and passes ttl through" do
        token = { token: "abc123", viewer_url: nil, expires_at: Time.now + 600 }
        fake = FakeImageAPI.new(returns: { launch_token: token })

        result = ImageGateway.launch_token(1, 555, ttl_seconds: 600, via: fake)

        assert_equal token, result
        assert_equal [ "1", "555" ], fake.calls.first[:args]
        assert_equal 600, fake.calls.first[:ttl_seconds]
      end

      test "launch_token defaults ttl_seconds when omitted" do
        fake = FakeImageAPI.new(returns: { launch_token: { token: "t", viewer_url: nil, expires_at: nil } })

        ImageGateway.launch_token(1, 555, via: fake)

        assert_equal 300, fake.calls.first[:ttl_seconds]
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
