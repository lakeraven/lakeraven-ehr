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
    # In lib/, not app/: a development code reload must not forget the broker
    # or drop every signed-in user's connection.
    #
    # The connections live in this process's memory, so the app runs as one
    # process (threads are fine): assert_single_process! refuses to boot
    # otherwise.
    module RpmsSessions
      # The user's connection is gone; they sign in again.
      class SignInAgain < StandardError; end

      # The app was started with more than one worker process.
      class MultipleProcesses < StandardError; end

      # Serialises a first service-account sign-on, so two concurrent first
      # requests do not both sign on.
      SERVICE_SIGNON = Mutex.new

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
          @service_duzes = Concurrent::Map.new
        end

        def enabled? = !@pool.nil?

        # A fresh client for one sign-on, not yet connected.
        def new_client = @factory.call

        # The pool key of a browser session: its SMART token, the credential
        # every way the session ends revokes.
        def key_for(token) = "token-#{token.id}"

        # The pool key of a Backend Services token's session on the service
        # account (ADR 0011 §6): the client application and its token, never a
        # person. Revoking the token releases it (ServiceAccountLeaseRelease).
        def service_key_for(token) = "system-app-#{token.application_id}-token-#{token.id}"

        # Run the block with the deployment's service account as RpmsRpc.client,
        # for a system/ token. Signs a fresh connection on at the token's first
        # request and leases it after; the keeper ends it once the token has
        # expired. Every failure fails closed as RpmsRpc::NotConfiguredError,
        # the 503 of a request with no RPMS connection: no service account
        # configured, a refused sign-on, a full pool, a lease that is gone or
        # signed on as someone else. Never another identity's connection.
        def with_service_account(token, &block)
          codes = ServiceAccount.codes
          raise RpmsRpc::NotConfiguredError, "no RPMS service account configured" unless codes

          key = service_key_for(token)
          idle_for = token_seconds_left(token)
          sign_on_service_account(key, codes) unless held?(key)
          touch(key, idle_for: idle_for)
          @pool.with_client(key) do |client|
            assert_service_identity!(key, client)
            RpmsRpc.with_client(client, &block)
          end
        rescue SignInAgain, RpmsRpc::SessionPool::PoolExhaustedError
          raise RpmsRpc::NotConfiguredError, "no service-account connection for this token"
        end

        # The token was revoked: end its service-account session, if any.
        def release_service_account(token) = release_service_account_key(service_key_for(token))

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
          @service_duzes = nil
        end

        private

        # The token's remaining lifetime in whole seconds, at least 1: the
        # service-account session never outlives the token.
        def token_seconds_left(token)
          expires_at = token.expires_at
          raise RpmsRpc::NotConfiguredError, "a non-expiring token gets no service account" unless expires_at

          [ (expires_at - Time.current).floor, 1 ].max
        end

        def sign_on_service_account(key, codes)
          SERVICE_SIGNON.synchronize do
            return if held?(key)

            @service_duzes.each_key { |held_key| @service_duzes.delete(held_key) unless held?(held_key) }
            client = new_client
            @service_duzes[key] = service_account_duz(key, client, codes)
            adopt(key, client)
          rescue RpmsRpc::SessionPool::SessionOccupiedError
            client&.disconnect # another sign-on holds the key: use that one
          rescue RpmsRpc::SessionPool::PoolExhaustedError
            client&.disconnect
            @service_duzes.delete(key)
            Rails.logger.warn("[rpms] service-account sign-on refused for #{key}: session pool full")
            raise RpmsRpc::NotConfiguredError, "RPMS session pool full"
          end
        end

        # Sign the fresh client on with the service account's codes, the way
        # the configured broker signs a user on; its DUZ, or fail closed.
        def service_account_duz(key, client, codes)
          auth = RpmsRpc.with_client(client) { AuthenticationService.new.sign_on(*codes) }
          duz = auth[:duz].to_s if auth[:success]
          return duz if duz.present? && duz != "0"

          refuse_service_sign_on(key, client, "refused")
        rescue StandardError => e
          raise if e.is_a?(RpmsRpc::NotConfiguredError)

          refuse_service_sign_on(key, client, e.class.name)
        end

        def refuse_service_sign_on(key, client, reason)
          client.disconnect
          Rails.logger.warn("[rpms] service-account sign-on failed for #{key}: #{reason}")
          raise RpmsRpc::NotConfiguredError, "service-account sign-on failed"
        end

        # Every checkout runs as the DUZ the lease signed on as (ADR 0011 §2).
        def assert_service_identity!(key, client)
          expected = @service_duzes[key]
          return if expected && client.duz.to_s == expected

          release_service_account_key(key)
          raise RpmsRpc::NotConfiguredError, "service-account connection is not the service account"
        end

        def release_service_account_key(key)
          @service_duzes.delete(key)
          release(key)
        end
      end
    end
  end
end
