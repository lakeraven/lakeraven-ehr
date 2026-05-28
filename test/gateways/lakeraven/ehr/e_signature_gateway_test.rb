# frozen_string_literal: true

require "test_helper"

# Tests for ESignatureGateway — TIU e-signature validate, which-action,
# add (sign/cosign/addend), and remove. Wraps RpmsRpc::ESignature
# (lakeraven/rpms-rpc#58).
module Lakeraven
  module EHR
    class ESignatureGatewayTest < ActiveSupport::TestCase
      class FakeESignatureAPI
        attr_reader :calls

        def initialize(returns: {})
          @returns = returns
          @calls = []
        end

        def validate(user_duz, signature_code)
          @calls << { method: :validate, args: [ user_duz, signature_code ] }
          @returns.fetch(:validate, true)
        end

        def which_action(note_ien, user_duz)
          @calls << { method: :which_action, args: [ note_ien, user_duz ] }
          @returns[:which_action]
        end

        def add(note_ien, user_duz, signature_code, action: :sign)
          @calls << { method: :add, args: [ note_ien, user_duz, signature_code ], action: action }
          @returns[:add] || { success: true, raw: "1" }
        end

        def remove(note_ien, user_duz, reason:)
          @calls << { method: :remove, args: [ note_ien, user_duz ], reason: reason }
          @returns[:remove] || { success: true, raw: "1" }
        end
      end

      # --- via: nil ---

      test "validate returns false when no provider is available" do
        refute ESignatureGateway.validate("301", "SECRET", via: nil)
      end

      test "which_action returns nil when no provider is available" do
        assert_nil ESignatureGateway.which_action(1001, "301", via: nil)
      end

      test "add returns failure shape when no provider is available" do
        assert_equal({ success: false, raw: nil },
          ESignatureGateway.add(1001, "301", "SECRET", via: nil))
      end

      test "remove returns failure shape when no provider is available" do
        assert_equal({ success: false, raw: nil },
          ESignatureGateway.remove(1001, "301", reason: "Entered in error", via: nil))
      end

      # --- delegation + coercion ---

      test "validate delegates with duz coerced to a string" do
        fake = FakeESignatureAPI.new(returns: { validate: true })

        assert ESignatureGateway.validate(301, "SECRET", via: fake)
        assert_equal [ "301", "SECRET" ], fake.calls.first[:args]
      end

      test "which_action delegates and passes the symbol through" do
        fake = FakeESignatureAPI.new(returns: { which_action: :sign })

        assert_equal :sign, ESignatureGateway.which_action(1001, 301, via: fake)
        assert_equal [ "1001", "301" ], fake.calls.first[:args]
      end

      test "add delegates with identifiers coerced and action symbol passed through" do
        fake = FakeESignatureAPI.new(returns: { add: { success: true, raw: "1" } })

        result = ESignatureGateway.add(1001, 301, "SECRET", action: :cosign, via: fake)

        assert_equal({ success: true, raw: "1" }, result)
        assert_equal [ "1001", "301", "SECRET" ], fake.calls.first[:args]
        assert_equal :cosign, fake.calls.first[:action]
      end

      test "add defaults to :sign when action is omitted" do
        fake = FakeESignatureAPI.new
        ESignatureGateway.add(1001, "301", "SECRET", via: fake)
        assert_equal :sign, fake.calls.first[:action]
      end

      test "remove delegates with identifiers coerced and reason forwarded" do
        fake = FakeESignatureAPI.new(returns: { remove: { success: true, raw: "1" } })

        result = ESignatureGateway.remove(1001, 301, reason: "Entered in error", via: fake)

        assert_equal({ success: true, raw: "1" }, result)
        assert_equal [ "1001", "301" ], fake.calls.first[:args]
        assert_equal "Entered in error", fake.calls.first[:reason]
      end

      # --- default_provider ---

      test "default_provider resolves to RpmsRpc::ESignature when the gem ships it" do
        provider = ESignatureGateway.default_provider
        refute_nil provider, "expected RpmsRpc::ESignature to be loaded via the gateway's guarded require"
        assert_equal "RpmsRpc::ESignature", provider.name
      end
    end
  end
end
