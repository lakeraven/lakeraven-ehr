# frozen_string_literal: true

module Lakeraven
  module EHR
    # Delivers due RPMS outbox rows (RpmsOutbox.dispatch). Safe to run on
    # several workers at once: rows are claimed with FOR UPDATE SKIP LOCKED.
    class RpmsOutboxDispatchJob < ApplicationJob
      queue_as :integrations

      def perform
        RpmsOutbox.dispatch
      end
    end
  end
end
