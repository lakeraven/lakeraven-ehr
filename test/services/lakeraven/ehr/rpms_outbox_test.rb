# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # Spec for #997: RPMS write-backs go through an outbox that delivers at
    # most once per row, retries with backoff and dead-letters. Synthetic
    # data only.
    class RpmsOutboxTest < ActiveSupport::TestCase
      EFFECT = "synthetic.write"
      PHI_MESSAGE = "TESTPATIENT,SYNTHETIC DFN 999 write refused"

      # name, handler script, dispatch rounds, final status, handler calls,
      # attempts, last_error_class (:any = not pinned)
      SCENARIOS = [
        [ "delivered once", [ :ok ], 3, "delivered", 1, 1, nil ],
        [ "transient failure then success", [ :fail, :ok ], 4, "delivered", 2, 2, :any ],
        [ "repeated failure ends dead-lettered", [ :fail ] * 5, 7, "dead", 5, 5, "RuntimeError" ]
      ].freeze

      setup { RpmsOutbox.reset_handlers! }
      teardown { RpmsOutbox.reset_handlers! }

      SCENARIOS.each do |name, script, rounds, status, calls, attempts, error_class|
        test "scenario: #{name}" do
          seen = register_script(script)
          entry = enqueue("key-#{name.parameterize}")
          assert_equal [ "pending", 0 ], [ entry.status, entry.attempts ]

          dispatch_rounds(entry, rounds)

          assert_equal status, entry.status
          assert_equal calls, seen.size, "handler call count"
          assert_equal attempts, entry.attempts
          assert_equal error_class, entry.last_error_class unless error_class == :any
          assert_not_nil entry.last_attempted_at
          assert_equal status == "delivered", entry.delivered_at.present?
          assert_equal status == "dead", entry.dead_lettered_at.present?
        end
      end

      test "the dead-letter scenario exhausts exactly MAX_ATTEMPTS" do
        assert_equal 5, RpmsOutbox::MAX_ATTEMPTS
      end

      test "a failed row is not retried before its next_attempt_at" do
        seen = register_script([ :fail, :ok ])
        entry = enqueue("key-backoff")
        now = Time.current

        assert_equal 1, RpmsOutbox.dispatch(now: now)
        assert_equal 0, RpmsOutbox.dispatch(now: now)

        assert_equal 1, seen.size
        assert_equal "pending", entry.reload.status
        assert_operator entry.next_attempt_at, :>, now
      end

      test "backoff is positive and grows with attempts" do
        waits = [ 1, 2, 3 ].map { |n| RpmsOutbox.backoff(n) }

        assert_operator waits.first, :>, 0
        assert_equal waits.sort, waits
        assert_equal waits.uniq, waits
      end

      test "the same idempotency key enqueued twice yields one row" do
        register_script([ :ok ])
        first = enqueue("key-dup", payload: { "n" => 1 })

        assert_no_difference -> { RpmsOutboxEntry.count } do
          assert_equal first.id, enqueue("key-dup", payload: { "n" => 2 }).id
        end
        assert_equal({ "n" => 1 }, first.reload.payload)
      end

      test "a caller's rollback leaves no row" do
        register_script([ :ok ])

        ActiveRecord::Base.transaction do
          enqueue("key-rolled-back")
          raise ActiveRecord::Rollback
        end

        assert_not RpmsOutboxEntry.exists?(idempotency_key: "key-rolled-back")
      end

      test "an unregistered effect or a blank key is refused" do
        register_script([ :ok ])

        assert_raises(ArgumentError) { RpmsOutbox.enqueue(effect: "synthetic.unknown", idempotency_key: "k", payload: {}) }
        assert_raises(ArgumentError) { enqueue("") }
        assert_raises(ArgumentError) { enqueue(nil) }
        assert_equal 0, RpmsOutboxEntry.count
      end

      test "a row stuck in delivering is never dispatched again" do
        seen = register_script([ :ok ])
        entry = enqueue("key-stuck")
        entry.update_columns(status: "delivering", attempts: 1)

        assert_equal 0, RpmsOutbox.dispatch(now: 1.day.from_now)
        assert_empty seen
        assert_equal "delivering", entry.reload.status
      end

      test "an effect with no handler at dispatch fails closed" do
        register_script([ :ok ])
        entry = enqueue("key-orphan")
        RpmsOutbox.reset_handlers!

        assert_equal 1, RpmsOutbox.dispatch

        entry.reload
        assert_equal [ "pending", 1 ], [ entry.status, entry.attempts ]
        assert_nil entry.delivered_at
        assert_equal "Lakeraven::EHR::RpmsOutbox::UnknownEffect", entry.last_error_class
      end

      test "error metadata on the row carries no PHI" do
        register_script([ :fail ] * 5)
        entry = enqueue("key-phi")
        dispatch_rounds(entry, 5)

        assert_equal "dead", entry.status
        # id is a sequence value, not error metadata; it may contain any digits.
        metadata = entry.attributes.except("payload", "id").values.map(&:to_s)
        assert_empty metadata.grep(/TESTPATIENT|999/)
        assert_empty RpmsOutboxEntry.column_names.grep(/message|backtrace/)
      end

      private

      # Registers a handler that follows +script+ call by call and returns
      # the array of idempotency keys it was called with.
      def register_script(script)
        seen = []
        RpmsOutbox.register(EFFECT, lambda { |_payload, idempotency_key:|
          seen << idempotency_key
          raise PHI_MESSAGE if script[seen.size - 1] == :fail
        })
        seen
      end

      def enqueue(key, payload: { "synthetic" => true })
        RpmsOutbox.enqueue(effect: EFFECT, idempotency_key: key, payload: payload)
      end

      # Dispatches +rounds+ times, moving the clock past the row's
      # next_attempt_at between rounds so every round finds a due retry.
      def dispatch_rounds(entry, rounds)
        now = Time.current
        rounds.times do
          RpmsOutbox.dispatch(now: now)
          now = [ now, entry.reload.next_attempt_at ].max + 1.second
        end
      end
    end
  end
end
