# frozen_string_literal: true

require "test_helper"

# Tests for ProgressNoteGateway — TIU progress note create, list, fetch,
# edit, lock. Signing lives in ESignatureGateway, not here.
# Wraps RpmsRpc::ProgressNote (lakeraven/rpms-rpc#57).
module Lakeraven
  module EHR
    class ProgressNoteGatewayTest < ActiveSupport::TestCase
      class FakeProgressNoteAPI
        attr_reader :calls

        def initialize(returns: {})
          @returns = returns
          @calls = []
        end

        def create(dfn, visit_ien, title_ien)
          @calls << { method: :create, args: [ dfn, visit_ien, title_ien ] }
          @returns[:create] || { success: true, ien: 1001, raw: "1001" }
        end

        def list(dfn, context: :all)
          @calls << { method: :list, args: [ dfn ], context: context }
          @returns[:list] || []
        end

        def fetch_text(note_ien)
          @calls << { method: :fetch_text, args: [ note_ien ] }
          @returns[:fetch_text]
        end

        def authorize(note_ien, user_duz)
          @calls << { method: :authorize, args: [ note_ien, user_duz ] }
          @returns.fetch(:authorize, true)
        end

        def lock(note_ien, user_duz)
          @calls << { method: :lock, args: [ note_ien, user_duz ] }
          @returns.fetch(:lock, true)
        end

        def update_text(note_ien, text)
          @calls << { method: :update_text, args: [ note_ien, text ] }
          @returns[:update_text] || { success: true, raw: "0" }
        end

        def unlock(note_ien, user_duz)
          @calls << { method: :unlock, args: [ note_ien, user_duz ] }
          @returns.fetch(:unlock, true)
        end
      end

      # --- via: nil ---

      test "create returns failure shape when no provider is available" do
        assert_equal({ success: false, ien: nil, raw: nil },
          ProgressNoteGateway.create(1, 2090061, 4321, via: nil))
      end

      test "list returns empty when no provider is available" do
        assert_equal [], ProgressNoteGateway.list(1, via: nil)
      end

      test "fetch_text returns nil when no provider is available" do
        assert_nil ProgressNoteGateway.fetch_text(1001, via: nil)
      end

      test "authorize returns false when no provider is available" do
        refute ProgressNoteGateway.authorize(1001, "301", via: nil)
      end

      test "lock returns false when no provider is available" do
        refute ProgressNoteGateway.lock(1001, "301", via: nil)
      end

      test "update_text returns failure shape when no provider is available" do
        assert_equal({ success: false, raw: nil },
          ProgressNoteGateway.update_text(1001, "S: ...", via: nil))
      end

      test "unlock returns false when no provider is available" do
        refute ProgressNoteGateway.unlock(1001, "301", via: nil)
      end

      # --- delegation + coercion ---

      test "create delegates with all identifiers coerced to strings" do
        fake = FakeProgressNoteAPI.new(returns: { create: { success: true, ien: 5050, raw: "5050" } })

        result = ProgressNoteGateway.create(1, 2090061, 4321, via: fake)

        assert_equal({ success: true, ien: 5050, raw: "5050" }, result)
        assert_equal [ "1", "2090061", "4321" ], fake.calls.first[:args]
      end

      test "list passes the context symbol through unchanged" do
        fake = FakeProgressNoteAPI.new(returns: { list: [ { ien: 1, title: "Office Visit" } ] })

        result = ProgressNoteGateway.list(1, context: :unsigned, via: fake)

        assert_equal 1, result.length
        assert_equal :unsigned, fake.calls.first[:context]
      end

      test "list defaults to :all when context is omitted" do
        fake = FakeProgressNoteAPI.new(returns: { list: [] })

        ProgressNoteGateway.list(1, via: fake)

        assert_equal :all, fake.calls.first[:context]
      end

      test "fetch_text delegates" do
        fake = FakeProgressNoteAPI.new(returns: { fetch_text: "S: HPI..." })

        assert_equal "S: HPI...", ProgressNoteGateway.fetch_text(1001, via: fake)
        assert_equal [ "1001" ], fake.calls.first[:args]
      end

      test "authorize delegates and returns boolean" do
        fake = FakeProgressNoteAPI.new(returns: { authorize: true })
        assert ProgressNoteGateway.authorize(1001, "301", via: fake)

        denied = FakeProgressNoteAPI.new(returns: { authorize: false })
        refute ProgressNoteGateway.authorize(1001, "301", via: denied)
      end

      test "lock delegates with identifiers coerced to strings" do
        fake = FakeProgressNoteAPI.new(returns: { lock: true })
        assert ProgressNoteGateway.lock(1001, 301, via: fake)
        assert_equal [ "1001", "301" ], fake.calls.first[:args]
      end

      test "update_text delegates and preserves the 2-key success shape" do
        fake = FakeProgressNoteAPI.new(returns: { update_text: { success: true, raw: "0" } })

        result = ProgressNoteGateway.update_text(1001, "S: revised note text", via: fake)

        assert_equal({ success: true, raw: "0" }, result)
        assert_equal [ "1001", "S: revised note text" ], fake.calls.first[:args]
      end

      test "unlock delegates" do
        fake = FakeProgressNoteAPI.new(returns: { unlock: true })
        assert ProgressNoteGateway.unlock(1001, "301", via: fake)
      end

      # --- default_provider ---

      test "default_provider resolves to RpmsRpc::ProgressNote when the gem ships it" do
        provider = ProgressNoteGateway.default_provider
        refute_nil provider, "expected RpmsRpc::ProgressNote to be loaded via the gateway's guarded require"
        assert_equal "RpmsRpc::ProgressNote", provider.name
      end
    end
  end
end
