# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class RpmsOutboxDispatchJobTest < ActiveSupport::TestCase
      setup { RpmsOutbox.reset_handlers! }
      teardown { RpmsOutbox.reset_handlers! }

      test "job uses integrations queue" do
        assert_equal "integrations", RpmsOutboxDispatchJob.new.queue_name
      end

      test "perform delivers a due pending row through its handler" do
        seen = []
        RpmsOutbox.register("synthetic.write", ->(payload, idempotency_key:) { seen << [ idempotency_key, payload ] })
        entry = RpmsOutbox.enqueue(effect: "synthetic.write", idempotency_key: "job-key-1", payload: { "n" => 1 })

        RpmsOutboxDispatchJob.perform_now

        assert_equal [ [ "job-key-1", { "n" => 1 } ] ], seen
        assert_equal "delivered", entry.reload.status
      end
    end
  end
end
