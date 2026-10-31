# frozen_string_literal: true

require "socket"
require "rpms_rpc/api/authentication"

module Lakeraven
  module EHR
    class AuthenticationService
      Result = Data.define(:success?, :value, :error)

      # Process-local serialization for the shared broker client, used until
      # the gem ships its own wire lock (rpms-rpc#235). It is a correct
      # DEGRADED serialization: the failure mode is two sign-ons in ONE process
      # sharing one global client, and one process holds one of these.
      BROKER_WIRE_MUTEX = Mutex.new
      private_constant :BROKER_WIRE_MUTEX

      # Sign on and resolve everything the session is built from.
      #
      # This spans SEVERAL calls into the gem — authenticate, then the user
      # lookup, the user class, then the user's keys — and they all read from one process-global
      # broker session. Locking each one individually is not enough: a second
      # sign-on landing between them returns THIS caller the other clinician's
      # name and security keys, which is to say their scopes. The whole
      # sequence is therefore one unit (rpms-rpc#235).
      #
      # NOTE: even serialized, one global client still holds one broker
      # identity — this narrows the window, it does not close it (rpms-rpc#234).
      #
      # client_ip is the browser's address. RPMS records it, with this
      # application's workstation name, against the sign-on
      # (docs/identity-passthrough.md).
      def authenticate(access_code:, verify_code:, client_ip: nil)
        return failure("Password required") if verify_code.to_s.empty?
        return authenticate_on_own_connection(access_code, verify_code, client_ip) if RpmsSessions.enabled?

        with_broker_wire_lock { resolve_signon(access_code, verify_code, client_ip) }
      end

      # What RPMS records as the workstation of a lakeraven-ehr sign-on (CIA
      # AUTH's WID): this application, and the host it runs on.
      def self.workstation = "lakeraven-ehr #{Socket.gethostname}"[0, 40]

      private

      # Sign on over a fresh connection of the user's own (ADR 0011 §3). The
      # whole sign-on sequence runs inside that connection's scope, so every
      # read in it (the user, class, keys, options, idle limit) asks the
      # connection that just signed on, and nothing is shared with any other
      # sign-on: no lock is needed. On success the value carries the client,
      # for the caller to adopt into RpmsSessions; on any failure the
      # connection is closed here.
      def authenticate_on_own_connection(access_code, verify_code, client_ip)
        client = RpmsSessions.new_client
        result = RpmsRpc.with_client(client) { resolve_signon(access_code, verify_code, client_ip) }
        return result.tap { client.disconnect } unless result.success?

        Result.new(success?: true, error: nil, value: result.value.merge(client: client))
      rescue StandardError
        client&.disconnect
        raise
      end

      # Prefer the gem's cross-client wire lock when present; otherwise fall
      # back to a process-local mutex rather than running unsynchronized. Do
      # NOT invert the guard — RpmsRpc.synchronize_wire is ABSENT on the gem
      # this branch pins, so requiring it would take login down. When
      # rpms-rpc#235 lands and the gem bumps, the first branch takes over
      # automatically.
      def with_broker_wire_lock(&block)
        return RpmsRpc.synchronize_wire(&block) if RpmsRpc.respond_to?(:synchronize_wire)

        Rails.logger.warn("[auth] broker wire lock unavailable (rpms-rpc#235); serialising in-process")
        BROKER_WIRE_MUTEX.synchronize(&block)
      end

      def resolve_signon(access_code, verify_code, client_ip)
        auth =
          if cia_broker?
            cia_signon(access_code, verify_code, client_ip)
          else
            RpmsRpc::Authentication.authenticate(access_code: access_code, verify_code: verify_code)
          end
        return failure(auth[:error] || "Invalid access/verify code") unless auth[:success]

        duz_s = auth[:duz].to_s
        user_info = fetch_user_info(duz_s)
        # The user class is the server's USRCLS from ORWU USERINFO, read for
        # the signed-on DUZ (rpms-rpc #236): XUS AV CODE carries no class
        # (its line 5 is the post-sign-on message count). user_type raises
        # when the class cannot be read, so the sign-on fails closed as
        # unavailable rather than defaulting a role.
        server_user_type = RpmsRpc::Authentication.user_type(duz_s)
        # The keys the policy table names, asked of RPMS for the signed-on
        # user. A key read that could not be made raises, and the sign-on is
        # refused as unavailable: never a session on keys nobody read (#578).
        symbolic_keys = Roles.symbolize_keys(SecurityKeyGateway.held(Roles::KEY_NAMES.values))
        # The options the policy grants from (the chart's CIAV VUECENTRIC), asked
        # the same way and refused the same way when they cannot be read.
        options = OptionAccessGateway.held(SessionScopePolicy::OPTION_SCOPES.keys)
        # How long RPMS lets this user sit idle (their DTIME): the session lasts
        # that long, on RPMS's clock. Not knowing it is not a refused sign-on;
        # the app's own limit applies instead.
        idle_seconds = rpms_idle_seconds(duz_s)

        # Round-trip the server's user type through the short code so
        # :referrals_supervisor or :referrals_manager still elevates to "case_manager".
        # A class the map does not know stays "user".
        Result.new(
          success?: true,
          error: nil,
          value: {
            duz: duz_s,
            name: user_info&.dig(:name) || auth[:name].to_s,
            user_type: Roles.resolve_signon(user_type: server_user_type, security_keys: symbolic_keys),
            security_keys: symbolic_keys,
            options: options,
            # RPMS said this verify code must be changed (admin reset, or aged
            # out). Dropping the flag granted a full session on a temporary
            # credential where CPRS would force the change first; the caller
            # decides, but it can only decide if it is told.
            verify_needs_change: auth[:verify_needs_change] == true,
            idle_seconds: idle_seconds,
            # The CIA session RPMS opened for this sign-on (nil over XWB).
            rpms_session_id: auth[:rpms_session_id]
          }
        )
      end

      # A CIA broker refuses every RPC but the CIANB* ones until CIANBRPC AUTH
      # has set a DUZ (CANRUN^CIANBACT), and XUS SIGNON SETUP kills DUZ
      # outright, so the XUS SIGNON SETUP / XUS AV CODE sequence can never sign
      # on there (#539). The client's own sign-on is the only way in.
      def cia_broker?
        defined?(RpmsRpc::CiaClient) && RpmsRpc.client.is_a?(RpmsRpc::CiaClient)
      end

      # CIA reports a verify code due for change only in the sign-on greeting
      # (VueCentric shows it and prompts); there is no flag field to read.
      VERIFY_CHANGE_GREETING = /VERIFY CODE must be changed/i

      def cia_signon(access_code, verify_code, client_ip)
        client = RpmsRpc.client
        client.connect unless client.connected?
        signon = client.authenticate(access_code, verify_code,
                                     workstation: self.class.workstation, workstation_ip: client_ip.presence)

        {
          success: true,
          duz: signon[:duz],
          name: signon[:user],
          verify_needs_change: VERIFY_CHANGE_GREETING.match?(signon[:greeting].to_s),
          rpms_session_id: client.session_uid
        }
      rescue RpmsRpc::Client::AuthenticationError => e
        # The gem sanitizes these messages (RpmsRpc.sanitize_error), so the
        # reason is safe to log; the clinician still sees one message for
        # every refusal.
        Rails.logger.warn("[auth] CIA sign-on refused: #{e.class}: #{e.message}")
        { success: false, error: "Invalid access/verify code" }
      end

      def rpms_idle_seconds(duz)
        RpmsRpc::Authentication.timed_read(duz)
      rescue RpmsRpc::Client::RpcError => e
        Rails.logger.warn("[auth] idle limit unavailable for DUZ #{duz}: #{e.class}")
        nil
      end

      def failure(message)
        Result.new(success?: false, value: nil, error: message)
      end

      # The display name only. Identity is the DUZ sign-on already verified,
      # so a refused read here is not a refused sign-on: a least-privilege
      # clinician on a CIA broker is denied XUS GET USER INFO outright (it is
      # not in CIAV VUECENTRIC's RPC multiple). The name the sign-on itself
      # resolved stands in.
      def fetch_user_info(duz)
        RpmsRpc::Authentication.user_info(duz)
      rescue RpmsRpc::Client::RpcError => e
        Rails.logger.warn("[auth] user info unavailable for DUZ #{duz}: #{e.message}")
        nil
      end
    end
  end
end
