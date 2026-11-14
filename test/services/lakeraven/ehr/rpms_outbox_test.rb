# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # Spec for #997: RPMS write-backs go through an outbox that delivers at
    # most once per row, retries only a definite non-delivery with backoff
    # and dead-letters. Synthetic data only.
    #
    # Transactional tests are OFF: dispatch refuses to run inside an open
    # transaction (the claim must commit before a handler writes to RPMS),
    # so the test cleans up its own rows.
    class RpmsOutboxTest < ActiveSupport::TestCase
      self.use_transactional_tests = false

      EFFECT = "synthetic.write"
      OTHER_EFFECT = "synthetic.other_write"
      NOT_DELIVERED = "Lakeraven::EHR::RpmsOutbox::NotDelivered"
      PHI_MESSAGE = "TESTPATIENT,SYNTHETIC DFN 999 write refused"

      # name, handler script, dispatch rounds, final status, handler calls,
      # attempts, last_error_class (nil = none; a delivered row carries none).
      # :fail raises NotDelivered (the write certainly did not reach RPMS);
      # :ambiguous raises anything else (outcome unknown, never retried).
      SCENARIOS = [
        [ "delivered once", [ :ok ], 3, "delivered", 1, 1, nil ],
        [ "transient failure then success", [ :fail, :ok ], 4, "delivered", 2, 2, nil ],
        [ "repeated failure ends dead-lettered", [ :fail ] * 5, 7, "dead", 5, 5, NOT_DELIVERED ],
        [ "ambiguous failure is never retried", [ :ambiguous, :ok ], 3, "dead", 1, 1, "RuntimeError" ]
      ].freeze

      setup do
        RpmsOutboxEntry.delete_all
        RpmsOutbox.reset_handlers!
      end

      teardown do
        RpmsOutbox.reset_handlers!
        RpmsOutboxEntry.delete_all
      end

      SCENARIOS.each do |name, script, rounds, status, calls, attempts, error_class|
        test "scenario: #{name}" do
          seen = register_script(script)
          entry = enqueue("key-#{name.parameterize}")
          assert_equal [ "pending", 0 ], [ entry.status, entry.attempts ]

          dispatch_rounds(entry, rounds)

          assert_equal status, entry.status
          assert_equal calls, seen.size, "handler call count"
          assert_equal attempts, entry.attempts
          if error_class.nil?
            assert_nil entry.last_error_class
          else
            assert_equal error_class, entry.last_error_class
          end
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

      test "the same key with the same effect and payload yields one row" do
        register_script([ :ok ])
        first = enqueue("key-dup", payload: { "n" => 1 })

        assert_no_difference -> { RpmsOutboxEntry.count } do
          assert_equal first.id, enqueue("key-dup", payload: { "n" => 1 }).id
          assert_equal first.id, enqueue("key-dup", payload: { n: 1 }).id
        end
        assert_equal({ "n" => 1 }, first.reload.payload)
      end

      test "the same key with a different payload or effect is a conflict" do
        register_script([ :ok ])
        RpmsOutbox.register(OTHER_EFFECT, ->(_payload, idempotency_key:) { })
        first = enqueue("key-conflict", payload: { "n" => 1 })

        assert_operator RpmsOutbox::IdempotencyConflict, :<, ArgumentError
        assert_no_difference -> { RpmsOutboxEntry.count } do
          assert_raises(RpmsOutbox::IdempotencyConflict) { enqueue("key-conflict", payload: { "n" => 2 }) }
          assert_raises(RpmsOutbox::IdempotencyConflict) do
            RpmsOutbox.enqueue(effect: OTHER_EFFECT, idempotency_key: "key-conflict", payload: { "n" => 1 })
          end
        end
        assert_equal [ EFFECT, { "n" => 1 } ], [ first.reload.effect, first.payload ]
      end

      test "a caller's rollback leaves no row" do
        register_script([ :ok ])

        ActiveRecord::Base.transaction do
          enqueue("key-rolled-back")
          raise ActiveRecord::Rollback
        end

        assert_not RpmsOutboxEntry.exists?(idempotency_key: "key-rolled-back")
      end

      test "an unregistered effect, a blank key or a non-Hash payload is refused" do
        register_script([ :ok ])

        assert_raises(ArgumentError) { RpmsOutbox.enqueue(effect: "synthetic.unknown", idempotency_key: "k", payload: {}) }
        assert_raises(ArgumentError) { enqueue("") }
        assert_raises(ArgumentError) { enqueue(nil) }
        assert_raises(ArgumentError) { enqueue("key-nil-payload", payload: nil) }
        assert_raises(ArgumentError) { enqueue("key-string-payload", payload: "x") }
        assert_equal 0, RpmsOutboxEntry.count
      end

      test "dispatch refuses to run inside an open transaction" do
        seen = register_script([ :ok ])
        entry = enqueue("key-open-transaction")

        assert_operator RpmsOutbox::TransactionOpen, :<, StandardError
        ActiveRecord::Base.transaction do
          assert_raises(RpmsOutbox::TransactionOpen) { RpmsOutbox.dispatch }
        end

        assert_empty seen
        assert_equal [ "pending", 0 ], [ entry.reload.status, entry.attempts ]
      end

      test "an interrupted batch strands only the in-flight row" do
        seen = []
        RpmsOutbox.register(EFFECT, lambda { |_payload, idempotency_key:|
          seen << idempotency_key
          raise Interrupt if seen.size == 1
        })
        3.times { |i| enqueue("key-interrupt-#{i}") }

        assert_raises(Interrupt) { RpmsOutbox.dispatch }

        assert_equal [ [ "delivering", 1 ], [ "pending", 0 ], [ "pending", 0 ] ],
          RpmsOutboxEntry.pluck(:status, :attempts).sort
        stranded = RpmsOutboxEntry.find_by!(status: "delivering")
        assert_equal [ stranded.idempotency_key ], seen

        assert_equal 2, RpmsOutbox.dispatch

        assert_equal 3, seen.size
        assert_equal seen.uniq, seen
        assert_equal [ "delivering", 1 ], [ stranded.reload.status, stranded.attempts ]
        assert_equal [ [ "delivered", 1 ] ] * 2,
          RpmsOutboxEntry.where.not(id: stranded.id).pluck(:status, :attempts)
      end

      test "recorded timestamps are the real attempt time, not a stale now" do
        register_script([ :fail ])
        entry = enqueue("key-stale-now")
        entry.update_columns(next_attempt_at: 2.hours.ago)

        assert_equal 1, RpmsOutbox.dispatch(now: 1.hour.ago)

        entry.reload
        assert_equal [ "pending", 1 ], [ entry.status, entry.attempts ]
        assert_in_delta Time.current.to_f, entry.last_attempted_at.to_f, 5
        assert_operator entry.next_attempt_at, :>, Time.current
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
          case script[seen.size - 1]
          when :fail then raise RpmsOutbox::NotDelivered, PHI_MESSAGE
          when :ambiguous then raise PHI_MESSAGE
          end
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
