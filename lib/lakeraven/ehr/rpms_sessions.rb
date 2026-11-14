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

      # After a refused or failed service-account sign-on, no new one is tried
      # for this many seconds, process-wide: a wrong code is not sent to RPMS
      # on every request.
      SERVICE_SIGNON_BACKOFF = 30

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
          @max_sessions = Integer(max_sessions)
          @service_duzes = Concurrent::Map.new
          # One sign-on lock per service key (per client application), so a
          # slow broker holds up only that application's first request.
          @service_signon_locks = Concurrent::Map.new
          @service_signon_failed_at = nil
        end

        def enabled? = !@pool.nil?

        # A fresh client for one sign-on, not yet connected.
        def new_client = @factory.call

        # The pool key of a browser session: its SMART token, the credential
        # every way the session ends revokes.
        def key_for(token) = "token-#{token.id}"

        # The pool key of a Backend Services token's session on the service
        # account (ADR 0011 §6): the client application, never a person. Every
        # live token of the application shares it, so one application takes one
        # slot however many tokens it holds; revoking any of them releases it
        # (ServiceAccountLeaseRelease).
        def service_key_for(token) = "system-app-#{token.application_id}"

        # Run the block with the deployment's service account as RpmsRpc.client,
        # for a system/ token. The application's first request signs a fresh
        # connection on and leases it; later ones reuse it, each keeping it for
        # the token's remaining lifetime. A request that gets no lease (no
        # service account configured, a refused sign-on or its back-off, a full
        # pool, a lease that is gone or signed on as someone else) runs with no
        # RPMS client at all: one that reaches for RPMS fails closed as
        # RpmsRpc::NotConfiguredError, one that does not answers as ever. Never
        # another identity's connection, and the block runs exactly once.
        def with_service_account(token, &block)
          key, signed_on = service_lease(token)
          ran = false
          result = nil
          begin
            if key
              result = @pool.with_client(key) do |client|
                next unless service_identity?(key, client)

                # A revocation committed while this request signed on found
                # nothing to release. Release now: this request, authorised
                # before it, finishes, and the pool logs the session off when
                # it checks the client back in, as for any in-flight request.
                release_service_account_key(key) if signed_on && revoked_now?(token)
                ran = true
                RpmsRpc.with_client(client, &block)
              end
            end
          rescue SignInAgain, RpmsRpc::SessionPool::PoolExhaustedError => e
            raise if ran # the action's own, never retried

            # Released between touch and checkout (its slot possibly taken).
            Rails.logger.warn("[rpms] service-account lease for #{key} ended before use: #{e.class.name}")
          end
          ran ? result : yield
        end

        # The token was revoked: end its application's service-account session, if any.
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
          @max_sessions = nil
          @service_duzes = nil
          @service_signon_locks = nil
          @service_signon_failed_at = nil
        end

        private

        # [key, signed_on]: the application's service key with a live lease
        # kept for the token's remaining lifetime, and whether this request
        # signed it on. nil when no lease can be had.
        def service_lease(token)
          idle_for = token_seconds_left(token)
          return nil unless idle_for

          key = service_key_for(token)
          signed_on = !live?(key)
          return nil if signed_on && !sign_on_service_account(key)

          [ key, signed_on ] if touch(key, idle_for: idle_for)
        end

        # The token's revocation as the database holds it now, not as this
        # request loaded it.
        def revoked_now?(token)
          Doorkeeper::AccessToken.where(id: token.id).where.not(revoked_at: nil).exists?
        end

        # The token's remaining lifetime in whole seconds, at least 1: the
        # service-account session never outlives the token. A non-expiring
        # token gets none.
        def token_seconds_left(token)
          expires_at = token.expires_at
          expires_at && [ (expires_at - Time.current).floor, 1 ].max
        end

        # Sign a fresh connection on as the service account and hold it under
        # key. True when a lease is held afterwards. Capacity, the back-off and
        # the codes are checked first, so a full pool builds no client.
        def sign_on_service_account(key)
          @service_signon_locks.compute_if_absent(key) { Mutex.new }.synchronize do
            return true if held?(key)
            return false if service_signon_backing_off?

            if @pool.size >= @max_sessions
              Rails.logger.warn("[rpms] service-account sign-on skipped for #{key}: session pool full")
              return false
            end

            codes = ServiceAccount.codes
            return false unless codes

            adopt_service_account(key, codes)
          end
        end

        def adopt_service_account(key, codes)
          client = build_service_client(key)
          return false unless client

          duz = service_account_duz(key, client, codes)
          return false unless duz

          @service_duzes[key] = duz
          adopt(key, client)
          true
        rescue RpmsRpc::SessionPool::PoolExhaustedError, RpmsRpc::SessionPool::SessionOccupiedError => e
          @service_duzes.delete(key)
          safe_disconnect(client)
          Rails.logger.warn("[rpms] service-account lease refused for #{key}: #{e.class.name}")
          false
        end

        # A fresh client from the factory, or nil having started the back-off:
        # a factory that raises is a failed sign-on like any other.
        def build_service_client(key)
          new_client
        rescue StandardError => e
          refuse_service_sign_on(key, nil, e.class.name)
        end

        # Sign the fresh client on with the service account's codes, the way
        # the configured broker signs a user on; its DUZ, or nil having closed
        # the connection and started the back-off.
        def service_account_duz(key, client, codes)
          auth = RpmsRpc.with_client(client) { AuthenticationService.new.sign_on(*codes) }
          duz = auth[:duz].to_s if auth[:success] && !auth[:verify_needs_change]
          return duz if duz.present? && duz != "0"

          refuse_service_sign_on(key, client, "refused")
        rescue StandardError => e
          refuse_service_sign_on(key, client, e.class.name)
        end

        def refuse_service_sign_on(key, client, reason)
          @service_signon_failed_at = Time.current
          safe_disconnect(client)
          Rails.logger.warn("[rpms] service-account sign-on failed for #{key}: #{reason}")
          nil
        end

        def service_signon_backing_off?
          failed_at = @service_signon_failed_at
          failed_at.present? && Time.current < failed_at + SERVICE_SIGNON_BACKOFF
        end

        def safe_disconnect(client)
          client&.disconnect
        rescue StandardError => e
          Rails.logger.warn("[rpms] service-account disconnect failed: #{e.class.name}")
        end

        # Every checkout runs as the DUZ the lease signed on as (ADR 0011 §2).
        # One that does not is released, never used.
        def service_identity?(key, client)
          expected = @service_duzes[key]
          return true if expected && client.duz.to_s == expected

          release_service_account_key(key)
          Rails.logger.warn("[rpms] service-account lease for #{key} is not the service account: released")
          false
        end

        def release_service_account_key(key)
          @service_duzes.delete(key)
          release(key)
        end
      end
    end
  end
end
