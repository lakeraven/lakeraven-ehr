# frozen_string_literal: true

require "securerandom"
require "rpms_rpc/core"
require "rpms_rpc/session_pool"

module Lakeraven
  module EHR
    # Each signed-in user's own RPMS connection (ADR 0011, #585). RPMS ties
    # identity to the connection: sign-on sets the M job's DUZ, and every RPC
    # on that socket runs as that user. So the web process holds no shared
    # client. Sign-on opens a fresh connection for the user and adopts it here
    # under a key kept in their browser session, every request runs inside
    # that connection's scope (RpmsRpc.with_client), and every way a session
    # ends releases it, so RPMS logs the user off. A request with no
    # connection of its own reaches no RPMS at all: RpmsRpc.client raises.
    #
    # The keeper keeps each connection open while its user may sit idle and
    # ends it after (SessionPool#touch). A connection the pool no longer holds
    # (a restart, an eviction, an idle end) is never rebuilt: the app keeps no
    # credentials, so the user signs in again (SignInAgain).
    module RpmsSessions
      # The user's connection is gone; they sign in again.
      class SignInAgain < StandardError; end

      class << self
        # Turned on at boot when config/rpms.yml names a broker. factory makes
        # one fresh, unconnected client; max_sessions caps how many users this
        # process holds at once (each is an M job on the RPMS host).
        def configure!(factory:, max_sessions:, keeper: true)
          @factory = factory
          @pool = RpmsRpc::SessionPool.new(
            max_sessions: max_sessions,
            build: ->(_key) { raise SignInAgain, "no RPMS connection for this session" }
          )
          @pool.start_keeper! if keeper
        end

        def enabled? = !@pool.nil?

        # A fresh client for one sign-on, not yet connected.
        def new_client = @factory.call

        # Hold an authenticated client for a new session, and return its key.
        # Raises RpmsRpc::SessionPool::PoolExhaustedError when every slot is in
        # use; the caller disconnects the client and refuses the sign-in.
        def adopt(client)
          key = SecureRandom.uuid
          @pool.adopt(key, client)
          key
        end

        # Run the block with the session's own connection as RpmsRpc.client.
        def with_user(key, &block)
          raise SignInAgain, "no RPMS connection for this session" if key.blank?

          @pool.with_client(key) { |client| RpmsRpc.with_client(client, &block) }
        end

        def held?(key) = key.present? && @pool.include?(key)

        # The user did something: keep their connection for idle_for seconds.
        def touch(key, idle_for:) = key.present? && @pool.touch(key, idle_for: idle_for)

        # The session ended: disconnect its connection.
        def release(key) = key.present? && @pool.release(key)

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
