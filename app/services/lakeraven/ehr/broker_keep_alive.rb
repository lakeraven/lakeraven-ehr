# frozen_string_literal: true

module Lakeraven
  module EHR
    # Keeps the RPMS broker session open while a signed-in user is active, on
    # RPMS's clock.
    #
    # The CIA listener ends a session that sends nothing for about 45 s
    # (CIANBLIS, measured on a 7c3119b build), far sooner than RPMS lets a user
    # sit idle (their DTIME, Authentication.timed_read: 600 s by default). So,
    # like VueCentric, this polls (CiaClient#poll) at RPMS's polling interval,
    # capped below the listener's cut, until the user's RPMS idle limit passes;
    # then it disconnects, RPMS ends the session, and the next page sends the
    # user to sign in (WebController).
    #
    # One per process, because the engine holds one broker client per process
    # (#585). A client that cannot poll (the test suite's mock) is left alone.
    class BrokerKeepAlive
      MAX_INTERVAL = 20

      def self.instance
        @instance ||= new
      end

      def initialize(client: -> { RpmsRpc.configuration.client })
        @client = client
        @deadline = nil
        @mutex = Mutex.new
        @thread = nil
      end

      # A signed-in user did something: keep the session for idle_seconds more.
      def touch!(idle_seconds, now: Time.now)
        @mutex.synchronize { @deadline = now + idle_seconds.to_i }
      end

      # One step: poll while inside the deadline, disconnect once past it.
      # Returns how long to wait before the next step.
      def tick(now: Time.now)
        broker = @client.call
        return MAX_INTERVAL unless broker.respond_to?(:poll) && broker.respond_to?(:connected?) && broker.connected?

        deadline = @mutex.synchronize { @deadline }
        return MAX_INTERVAL if deadline.nil?

        if now < deadline
          interval = broker.poll[:interval].to_i
          interval.positive? ? [ interval, MAX_INTERVAL ].min : MAX_INTERVAL
        else
          @mutex.synchronize { @deadline = nil }
          broker.disconnect
          MAX_INTERVAL
        end
      rescue RpmsRpc::Error, IOError, SystemCallError => e
        Rails.logger.warn("[rpms] keep-alive: #{e.class}")
        MAX_INTERVAL
      end

      # Run the steps on a background thread, once per process.
      def start!
        @mutex.synchronize do
          return if @thread&.alive?

          @thread = Thread.new do
            Thread.current.name = "rpms-keep-alive"
            loop { sleep tick }
          end
        end
      end
    end
  end
end
