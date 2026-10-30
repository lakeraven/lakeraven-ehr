# frozen_string_literal: true

require "rpms_rpc/core"
require "rpms_rpc/session_pool"

module Lakeraven
  module EHR
    # Each signed-in user's own RPMS connection (ADR 0011, #585). RPMS ties
    # identity to the connection: sign-on sets the M job's DUZ, and every RPC
    # on that socket runs as that user. So the web process holds no shared
    # client. Sign-on opens a fresh connection for the user and adopts it here,
    # keyed to the browser session's credential (its SMART token): every
    # request runs inside that connection's scope (RpmsRpc.with_client), and
    # every way the session ends, the token's revocation included, releases
    # it, so RPMS logs the user off. A request with no connection of its own
    # reaches no RPMS at all: RpmsRpc.client raises.
    #
    # The keeper keeps each connection open while its user may sit idle and
    # ends it after (SessionPool#touch), and releases one the broker dropped.
    # A connection the pool no longer holds (a restart, an idle end, a
    # revocation) is never rebuilt: the app keeps no credentials, so the user
    # signs in again (SignInAgain). At capacity sign-in is refused; no signed-in
    # user is evicted to make room (evict_idle: false).
    #
    # The connections live in this process's memory, so the app runs as one
    # process (threads are fine): assert_single_process! refuses to boot
    # otherwise.
    module RpmsSessions
      # The user's connection is gone; they sign in again.
      class SignInAgain < StandardError; end

      # The app was started with more than one worker process.
      class MultipleProcesses < StandardError; end

      class << self
        # Turned on at boot when config/rpms.yml names a broker. factory makes
        # one fresh, unconnected client; max_sessions caps how many users this
        # process holds at once (each is an M job on the RPMS host).
        def configure!(factory:, max_sessions:, keeper: true)
          @factory = factory
          @pool = RpmsRpc::SessionPool.new(
            max_sessions: max_sessions, evict_idle: false,
            build: ->(_key) { raise SignInAgain, "no RPMS connection for this session" }
          )
          @pool.start_keeper! if keeper
        end

        def enabled? = !@pool.nil?

        # A fresh client for one sign-on, not yet connected.
        def new_client = @factory.call

        # The pool key of a browser session: its SMART token, the credential
        # every way the session ends revokes.
        def key_for(token) = "token-#{token.id}"

        # Hold an authenticated client under the session's key. Raises
        # RpmsRpc::SessionPool::PoolExhaustedError at capacity; the caller
        # disconnects the client and refuses the sign-in.
        def adopt(key, client) = @pool.adopt(key, client)

        # Run the block with the session's own connection as RpmsRpc.client.
        def with_user(key, &block)
          raise SignInAgain, "no RPMS connection for this session" if key.blank?

          @pool.with_client(key) { |client| RpmsRpc.with_client(client, &block) }
        end

        def held?(key) = key.present? && @pool.include?(key)

        # Whether the session's connection is held AND still connected. One the
        # broker dropped is released here, so its session ends.
        def live?(key)
          return false unless held?(key)

          connected = @pool.with_client(key) { |c| !c.respond_to?(:connected?) || c.connected? }
          release(key) unless connected
          connected
        rescue SignInAgain, RpmsRpc::SessionPool::PoolExhaustedError
          false
        end

        # The user did something: keep their connection for idle_for seconds.
        def touch(key, idle_for:) = key.present? && @pool.touch(key, idle_for: idle_for)

        # The session ended: disconnect its connection.
        def release(key) = key.present? && @pool.release(key)

        # Refuse to serve per-user connections from a multi-process server:
        # a request routed to a process that does not hold its user's
        # connection would sign them out, and a load balancer's stickiness
        # picks an instance, not a Puma worker.
        def assert_single_process!(workers: puma_workers)
          return if workers.to_i <= 1

          raise MultipleProcesses,
                "lakeraven-ehr holds each signed-in user's RPMS connection in process memory: " \
                "run one Puma process per instance (#{workers} workers configured; set WEB_CONCURRENCY to 1 " \
                "and raise RAILS_MAX_THREADS instead)"
        end

        def puma_workers
          from_puma = defined?(::Puma) && ::Puma.respond_to?(:cli_config) && ::Puma.cli_config&.options&.[](:workers)
          [ (from_puma || 0).to_i, ENV["WEB_CONCURRENCY"].to_i ].max
        end

        # Tests only: drop the pool and stop its keeper.
        def reset!
          @pool&.stop_keeper!
          @pool&.shutdown
          @pool = nil
          @factory = nil
        end
      end
    end
  end
end
