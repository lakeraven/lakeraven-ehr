# frozen_string_literal: true

require "test_helper"

# Spec for #997: two dispatchers running together never deliver the same
# row twice. Transactional tests are OFF, deliberately: SKIP LOCKED only
# means something across separate connections, so each dispatcher thread
# checks out its own and the test cleans up its own rows.
class RpmsOutboxConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  EFFECT = "synthetic.concurrent_write"
  ROWS = 20
  DISPATCHERS = 4

  setup do
    Lakeraven::EHR::RpmsOutboxEntry.delete_all
    Lakeraven::EHR::RpmsOutbox.reset_handlers!
  end

  teardown do
    Lakeraven::EHR::RpmsOutbox.reset_handlers!
    Lakeraven::EHR::RpmsOutboxEntry.delete_all
  end

  test "concurrent dispatchers deliver every row exactly once" do
    outbox = Lakeraven::EHR::RpmsOutbox
    delivered = []
    lock = Mutex.new
    outbox.register(EFFECT, lambda { |_payload, idempotency_key:|
      sleep 0.01
      lock.synchronize { delivered << idempotency_key }
    })
    keys = Array.new(ROWS) { |i| "concurrent-#{i}" }
    keys.each { |key| outbox.enqueue(effect: EFFECT, idempotency_key: key, payload: { "n" => 1 }) }

    gate = Queue.new
    threads = Array.new(DISPATCHERS) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          gate.pop
          # Small batches keep all dispatchers contending for the same rows.
          nil until outbox.dispatch(limit: 3).zero?
        end
      end
    end
    DISPATCHERS.times { gate << :go }
    threads.each(&:join)

    assert_equal keys.sort, delivered.sort, "every key delivered exactly once"
    assert_equal [ "delivered" ], Lakeraven::EHR::RpmsOutboxEntry.distinct.pluck(:status)
    assert_equal [ 1 ], Lakeraven::EHR::RpmsOutboxEntry.distinct.pluck(:attempts)
  end
end
