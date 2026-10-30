# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # BrokerKeepAlive keeps the RPMS broker session open while a signed-in user
    # is active, on RPMS's clock: it polls (CiaClient#poll) until the user's RPMS
    # idle limit passes, then disconnects so RPMS ends the session. One #tick is
    # one step; the thread only repeats it.
    class BrokerKeepAliveTest < ActiveSupport::TestCase
      # Answers like a CiaClient (poll's shape is a live 7c3119b reply).
      class Broker
        attr_reader :polls, :disconnects
        attr_accessor :interval

        def initialize(interval: 5)
          @interval = interval
          @polls = 0
          @disconnects = 0
          @connected = true
        end

        def connected? = @connected

        def poll
          @polls += 1
          { interval: interval, server_time: Time.now }
        end

        def disconnect
          @disconnects += 1
          @connected = false
        end
      end

      T0 = Time.utc(2026, 10, 30, 12, 0, 0)

      def keeper(broker) = BrokerKeepAlive.new(client: -> { broker })

      test "while the user is inside their RPMS idle limit, it polls at RPMS's interval" do
        broker = Broker.new(interval: 5)
        k = keeper(broker)
        k.touch!(600, now: T0)

        assert_equal 5, k.tick(now: T0 + 30)
        assert_equal 5, k.tick(now: T0 + 599)
        assert_equal 2, broker.polls
        assert_equal 0, broker.disconnects
      end

      test "an interval longer than the broker keeps an idle session is capped" do
        broker = Broker.new(interval: 60)
        k = keeper(broker)
        k.touch!(600, now: T0)

        assert_equal BrokerKeepAlive::MAX_INTERVAL, k.tick(now: T0 + 1)
        assert_operator BrokerKeepAlive::MAX_INTERVAL, :<, 45, "the listener ends a quiet session at about 45 s"
      end

      test "once the user's RPMS idle limit passes, it disconnects once and stops polling" do
        broker = Broker.new
        k = keeper(broker)
        k.touch!(600, now: T0)

        k.tick(now: T0 + 601)
        k.tick(now: T0 + 700)

        assert_equal 0, broker.polls
        assert_equal 1, broker.disconnects
      end

      test "activity moves the deadline on" do
        broker = Broker.new
        k = keeper(broker)
        k.touch!(600, now: T0)
        k.touch!(600, now: T0 + 500)

        k.tick(now: T0 + 1000)

        assert_equal 1, broker.polls
        assert_equal 0, broker.disconnects
      end

      test "a client that cannot poll, or is not connected, is left alone" do
        k = BrokerKeepAlive.new(client: -> { Object.new })
        k.touch!(600, now: T0)
        assert_equal BrokerKeepAlive::MAX_INTERVAL, k.tick(now: T0 + 1)

        broker = Broker.new
        broker.disconnect
        k = keeper(broker)
        k.touch!(600, now: T0)
        k.tick(now: T0 + 1)
        assert_equal 0, broker.polls
      end
    end
  end
end
