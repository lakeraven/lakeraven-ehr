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

      class NotDelivered < StandardError; end
      class UnknownEffect < NotDelivered; end
      class TransactionOpen < StandardError; end
      class IdempotencyConflict < ArgumentError; end

      @handlers = {}
      @handlers_lock = Mutex.new

      class << self
        def register(effect, handler)
          @handlers_lock.synchronize { @handlers[effect.to_s] = handler }
        end

        def reset_handlers!
          @handlers_lock.synchronize { @handlers.clear }
        end

        # Inserts in the caller's open transaction. A repeated key with the
        # same effect and payload is a no-op (ON CONFLICT DO NOTHING, which
        # does not abort the caller's transaction) and returns the row first
        # written for it; with a different effect or payload it raises
        # IdempotencyConflict.
        def enqueue(effect:, idempotency_key:, payload: {})
          effect = effect.to_s
          raise ArgumentError, "RPMS outbox payload must be a Hash" unless payload.is_a?(Hash)
          raise ArgumentError, "unregistered RPMS outbox effect" unless handler_for(effect)
          raise ArgumentError, "RPMS outbox idempotency_key is required" if idempotency_key.blank?

          payload = payload.deep_stringify_keys.as_json
          now = Time.current
          RpmsOutboxEntry.insert_all(
            [ { effect: effect, idempotency_key: idempotency_key, payload: payload,
                status: RpmsOutboxEntry::PENDING, attempts: 0, next_attempt_at: now,
                created_at: now, updated_at: now } ],
            unique_by: :idx_rpms_outbox_idempotency_key
          )
          entry = RpmsOutboxEntry.find_by!(idempotency_key: idempotency_key)
          unless entry.effect == effect && entry.payload == payload
            raise IdempotencyConflict, "idempotency key already used for a different effect or payload"
          end

          entry
        end

        # Claims and delivers due rows one at a time, up to +limit+. Refuses
        # an open transaction: a claim joined to it would not be committed
        # before the handler writes to RPMS. Returns the number claimed.
        def dispatch(now: Time.current, limit: DEFAULT_BATCH)
          raise TransactionOpen, "RPMS outbox dispatch must run outside a transaction" if
            RpmsOutboxEntry.connection.transaction_open?

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

        def handler_for(effect)
          @handlers_lock.synchronize { @handlers[effect] }
        end

        def claim(now)
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
              last_error_class: error.class.name)
          else
            finish(entry, status: RpmsOutboxEntry::DEAD, dead_lettered_at: stamp, last_error_class: error.class.name)
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
