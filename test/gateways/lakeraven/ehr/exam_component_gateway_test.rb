# frozen_string_literal: true

require "test_helper"

# Tests for ExamComponentGateway — visit exam-component entry.
# Wraps RpmsRpc::ExamComponent (lakeraven/rpms-rpc#66).
module Lakeraven
  module EHR
    class ExamComponentGatewayTest < ActiveSupport::TestCase
      class FakeExamAPI
        attr_reader :calls

        def initialize(returns:)
          @returns = returns
          @calls = []
        end

        def add(dfn, visit_ien, exam_code, **opts)
          @calls << { dfn:, visit_ien:, exam_code:, opts: }
          @returns
        end
      end

      test "add returns failure shape when no provider is available" do
        result = ExamComponentGateway.add(1, 2090061, "SKIN", finding: "Normal", via: nil)
        assert_equal({ success: false, ien: nil, raw: nil }, result)
      end

      test "add delegates with identifiers coerced to strings" do
        fake = FakeExamAPI.new(returns: { success: true, ien: 9, raw: "9" })

        result = ExamComponentGateway.add(1, 2090061, "SKIN",
          finding: "Normal",
          narrative: "Skin: WNL",
          via: fake)

        assert_equal({ success: true, ien: 9, raw: "9" }, result)
        call = fake.calls.first
        assert_equal "1", call[:dfn]
        assert_equal "2090061", call[:visit_ien]
        assert_equal "SKIN", call[:exam_code]
        assert_equal "Normal", call[:opts][:finding]
      end

      test "default_provider resolves to RpmsRpc::ExamComponent when the gem ships it" do
        provider = ExamComponentGateway.default_provider
        refute_nil provider, "expected RpmsRpc::ExamComponent to be loaded via the gateway's guarded require"
        assert_equal "RpmsRpc::ExamComponent", provider.name
      end
    end
  end
end
