# frozen_string_literal: true

module Lakeraven
  module EHR
    # Transactional outbox for RPMS write-backs (#997). A side effect is
    # enqueued in the same transaction as the change that caused it, so a
    # rollback leaves nothing to deliver; RpmsOutboxDispatchJob delivers it.
    #
    # Delivery is at most once per row. Rows are claimed one at a time
    # (pending -> delivering, attempts + 1), each claim in its own committed
    # transaction before its handler runs, so an interruption strands at most
    # the in-flight row. A row left in delivering (worker died mid-call) is
    # never picked up again, because the write may already have reached RPMS.
    #
    # Handler contract: call(payload, idempotency_key:). Return normally when
    # RPMS accepted the write. Raise NotDelivered only when the write
    # certainly did not reach RPMS; it is retried with exponential backoff and
    # dead-lettered after MAX_ATTEMPTS. Any other StandardError means the
    # outcome is unknown, and the row is dead-lettered at once rather than
    # risk a second delivery. Pass the key to RPMS where it supports one.
    #
    # Only the error class is recorded: exception messages from RPMS can
    # carry PHI, so no raised message here names a payload value or key.
    module RpmsOutbox
      MAX_ATTEMPTS = 5
      BASE_BACKOFF = 30.seconds
      DEFAULT_BATCH = 50
      UNSTORABLE = "RPMS outbox payload cannot be stored"

      class NotDelivered < StandardError; end
      class UnknownEffect < NotDelivered; end
      class TransactionOpen < StandardError; end
      class IdempotencyConflict < ArgumentError; end

      @handlers = {}
      @handlers_lock = Mutex.new

      class << self
        def register(effect, handler)
          raise ArgumentError, "RPMS outbox handler must respond to call" unless handler.respond_to?(:call)

          @handlers_lock.synchronize { @handlers[effect.to_s] = handler }
        end

        def reset_handlers!
          @handlers_lock.synchronize { @handlers.clear }
        end

        # Inserts in the caller's open transaction. The payload is validated
        # before any SQL (see storable?), then written with bound values, so
        # no error or log line quotes it. The insert runs in a savepoint
        # (create_or_find_by!), so a duplicate key does not abort the
        # caller's transaction: a repeated key with the same effect and
        # payload is a no-op that returns the row first written for it; with
        # a different effect or payload it raises IdempotencyConflict. Any
        # other database error propagates as itself.
        def enqueue(effect:, idempotency_key:, payload: {})
          effect = effect.to_s
          raise ArgumentError, "RPMS outbox payload must be a Hash" unless payload.is_a?(Hash)
          raise ArgumentError, "unregistered RPMS outbox effect" unless handler_for(effect)
          raise ArgumentError, "RPMS outbox idempotency_key is required" if idempotency_key.blank?
          raise ArgumentError, UNSTORABLE unless storable?(payload)

          payload = payload.deep_stringify_keys.as_json
          now = Time.current
          entry = RpmsOutboxEntry.create_or_find_by!(idempotency_key: idempotency_key) do |row|
            row.effect = effect
            row.payload = payload
            row.status = RpmsOutboxEntry::PENDING
            row.attempts = 0
            row.next_attempt_at = now
          end
          unless entry.effect == effect && entry.payload == payload
            raise IdempotencyConflict, "idempotency key already used for a different effect or payload"
          end

          entry
        end

        # Claims and delivers due rows one at a time, up to +limit+. Refuses
        # an open transaction: a claim joined to it would not be committed
        # before the handler writes to RPMS. Returns the number claimed.
        def dispatch(now: Time.current, limit: DEFAULT_BATCH)
          refuse_open_transaction!
          count = 0
          while count < limit && (entry = claim(now))
            count += 1
            deliver(entry, now)
          end
          count
        end

        def backoff(attempts)
          BASE_BACKOFF * (2**(attempts - 1))
        end

        private

        def refuse_open_transaction!
          raise TransactionOpen, "RPMS outbox dispatch must run outside a transaction" if
            RpmsOutboxEntry.with_connection(&:transaction_open?)
        end

        # Only JSON-safe values: String, Symbol, Integer, finite Float,
        # true/false/nil and Hash/Array of those, with String or Symbol keys
        # that stay distinct once stringified. Every string must be valid
        # UTF-8 (or plain ASCII) without NUL, which jsonb cannot store.
        def storable?(value)
          case value
          when Hash
            value.keys.map(&:to_s).uniq.size == value.size &&
              value.all? { |k, v| (k.is_a?(String) || k.is_a?(Symbol)) && storable_string?(k.to_s) && storable?(v) }
          when Array then value.all? { |v| storable?(v) }
          when String then storable_string?(value)
          when Symbol then storable_string?(value.name)
          when Float then value.finite?
          when Integer, true, false, nil then true
          else false
          end
        end

        def storable_string?(string)
          utf8 = (string.encoding == Encoding::UTF_8 && string.valid_encoding?) || string.ascii_only?
          utf8 && !string.include?("\u0000")
        end

        def error_name(error)
          error.class.ancestors.find { |c| c.is_a?(Class) && c.name }.name
        end

        def handler_for(effect)
          @handlers_lock.synchronize { @handlers[effect] }
        end

        def claim(now)
          refuse_open_transaction!
          RpmsOutboxEntry.transaction do
            row = RpmsOutboxEntry.where(status: RpmsOutboxEntry::PENDING)
              .where(next_attempt_at: ..now)
              .order(:next_attempt_at, :id)
              .limit(1)
              .lock("FOR UPDATE SKIP LOCKED")
              .first
            next unless row

            stamp = [ now, Time.current ].max
            row.update_columns(status: RpmsOutboxEntry::DELIVERING, attempts: row.attempts + 1,
              last_attempted_at: stamp, updated_at: stamp)
            row
          end
        end

        # Only the handler call is rescued: a failure to record the outcome
        # must not be mistaken for a failed delivery.
        def deliver(entry, now)
          handler = handler_for(entry.effect)
          raise UnknownEffect, "no handler registered for this effect" unless handler

          handler.call(entry.payload, idempotency_key: entry.idempotency_key)
        rescue StandardError => e
          record_failure(entry, e, [ now, Time.current ].max)
        else
          finish(entry, status: RpmsOutboxEntry::DELIVERED, delivered_at: [ now, Time.current ].max,
            last_error_class: nil)
        end

        def record_failure(entry, error, stamp)
          if error.is_a?(NotDelivered) && entry.attempts < MAX_ATTEMPTS
            finish(entry, status: RpmsOutboxEntry::PENDING, next_attempt_at: stamp + backoff(entry.attempts),
              last_error_class: error_name(error))
          else
            finish(entry, status: RpmsOutboxEntry::DEAD, dead_lettered_at: stamp, last_error_class: error_name(error))
          end
        end

        # Conditional on the row still being this claim, so a stale writer
        # cannot overwrite a later claim's outcome.
        def finish(entry, **attributes)
          RpmsOutboxEntry.where(id: entry.id, status: RpmsOutboxEntry::DELIVERING, attempts: entry.attempts)
            .update_all(attributes.merge(updated_at: Time.current))
        end
      end
    end
  end
end
