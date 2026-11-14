# frozen_string_literal: true

module Lakeraven
  module EHR
    # Transactional outbox for RPMS write-backs (#997). A side effect is
    # enqueued in the same transaction as the change that caused it, so a
    # rollback leaves nothing to deliver; RpmsOutboxDispatchJob delivers it.
    #
    # Delivery is at most once per row: a row is claimed (pending ->
    # delivering, attempts + 1) and committed before its handler runs, and a
    # row left in delivering (worker died mid-call) is never picked up again,
    # because the write may already have reached RPMS. Failures retry with
    # exponential backoff and are dead-lettered after MAX_ATTEMPTS. Only the
    # error class is recorded: exception messages from RPMS can carry PHI.
    module RpmsOutbox
      MAX_ATTEMPTS = 5
      BASE_BACKOFF = 30.seconds
      DEFAULT_BATCH = 50

      class UnknownEffect < StandardError; end

      @handlers = {}
      @handlers_lock = Mutex.new

      class << self
        # +handler+ responds to call(payload, idempotency_key:) and raises on
        # failure. Pass the key to RPMS where it supports one.
        def register(effect, handler)
          @handlers_lock.synchronize { @handlers[effect.to_s] = handler }
        end

        def reset_handlers!
          @handlers_lock.synchronize { @handlers.clear }
        end

        # Inserts in the caller's open transaction. A repeated key is a no-op
        # (ON CONFLICT DO NOTHING, which does not abort the caller's
        # transaction) and returns the row first written for it.
        def enqueue(effect:, idempotency_key:, payload: {})
          effect = effect.to_s
          raise ArgumentError, "unregistered RPMS outbox effect: #{effect}" unless handler_for(effect)
          raise ArgumentError, "RPMS outbox idempotency_key is required" if idempotency_key.blank?

          now = Time.current
          RpmsOutboxEntry.insert_all(
            [ { effect: effect, idempotency_key: idempotency_key, payload: payload,
                status: RpmsOutboxEntry::PENDING, attempts: 0, next_attempt_at: now,
                created_at: now, updated_at: now } ],
            unique_by: :idx_rpms_outbox_idempotency_key
          )
          RpmsOutboxEntry.find_by!(idempotency_key: idempotency_key)
        end

        # Claims up to +limit+ due rows and delivers each. Call it outside a
        # transaction: the claim must commit before a handler touches RPMS.
        # Returns the number of rows claimed.
        def dispatch(now: Time.current, limit: DEFAULT_BATCH)
          claimed = claim(now, limit)
          claimed.each { |entry| deliver(entry, now) }
          claimed.size
        end

        def backoff(attempts)
          BASE_BACKOFF * (2**(attempts - 1))
        end

        private

        def handler_for(effect)
          @handlers_lock.synchronize { @handlers[effect] }
        end

        def claim(now, limit)
          RpmsOutboxEntry.transaction do
            rows = RpmsOutboxEntry.where(status: RpmsOutboxEntry::PENDING)
              .where(next_attempt_at: ..now)
              .order(:next_attempt_at, :id)
              .limit(limit)
              .lock("FOR UPDATE SKIP LOCKED")
              .to_a
            rows.each do |row|
              row.update_columns(status: RpmsOutboxEntry::DELIVERING, attempts: row.attempts + 1,
                last_attempted_at: now, updated_at: now)
            end
            rows
          end
        end

        # Only the handler call is rescued: a failure to record the outcome
        # must not be mistaken for a failed delivery.
        def deliver(entry, now)
          handler = handler_for(entry.effect)
          raise UnknownEffect, "no handler registered for #{entry.effect}" unless handler

          handler.call(entry.payload, idempotency_key: entry.idempotency_key)
        rescue StandardError => e
          record_failure(entry, e, now)
        else
          finish(entry, status: RpmsOutboxEntry::DELIVERED, delivered_at: now, last_error_class: nil)
        end

        def record_failure(entry, error, now)
          if entry.attempts >= MAX_ATTEMPTS
            finish(entry, status: RpmsOutboxEntry::DEAD, dead_lettered_at: now, last_error_class: error.class.name)
          else
            finish(entry, status: RpmsOutboxEntry::PENDING, next_attempt_at: now + backoff(entry.attempts),
              last_error_class: error.class.name)
          end
        end

        # Conditional on the row still being ours, so a stale writer cannot
        # overwrite an outcome.
        def finish(entry, **attributes)
          RpmsOutboxEntry.where(id: entry.id, status: RpmsOutboxEntry::DELIVERING)
            .update_all(attributes.merge(updated_at: Time.current))
        end
      end
    end
  end
end
