# frozen_string_literal: true

require "rpms_rpc/api/adt"

module Lakeraven
  module EHR
    # BPRM twin — ADT movement group (scenario #15).
    #
    # Inpatient admit / transfer / discharge / cancel-movement.
    #
    # WRITE PATH IS BLOCKED. The #8994 registry dump (rpms-rpc#171) confirms
    # there is NO stock movement-WRITE RPC: admit/transfer/discharge/cancel have
    # no broker-callable entry point. BPRM's Bdg* SQL-MUTATE procs raw-write
    # ^DGPM (INPATIENT MOVEMENT #405) and bypass the movement cross-references
    # that keep the inpatient census correct — we must not paper over that with
    # an invented RPC. Each write therefore returns a 501 "blocked" result and
    # never touches the broker; unblocking needs a FileMan-safe ^DIE/DGPMV*
    # server RPC to be authored and re-exported (rpms-ops#366).
    #
    # READ PATH is live: the confirmed ORWPT movement reads (ADMITLST/INPLOC)
    # go through the gem's RpmsRpc::Adt wrapper.
    #
    # See docs/BPRM_REG_SCHED_TWIN.md for the scenario→RPC mapping.
    class AdtGateway
      # BLOCKED: needs a FileMan-safe ^DIE/DGPMV* server RPC authored (see rpms-rpc#171 notes).
      BLOCKED_MESSAGE =
        "ADT movement writes are unavailable: no stock FileMan-safe movement-write RPC exists in #8994"

      UNAVAILABLE = "ADT service unavailable"

      class << self
        # --- Admit (POST /patients/:dfn/movements) -------------------------
        # BLOCKED: needs a FileMan-safe ^DIE/DGPMV* server RPC authored (see rpms-rpc#171 notes).
        def admit(dfn, ward_ien, at:, provider:)
          movement_blocked(:admission, dfn: dfn, ward_ien: ward_ien, at: at, provider: provider)
        end

        # --- Transfer (POST /patients/:dfn/movements/transfer) -------------
        # BLOCKED: needs a FileMan-safe ^DIE/DGPMV* server RPC authored (see rpms-rpc#171 notes).
        def transfer(dfn, ward_ien, at:)
          movement_blocked(:transfer, dfn: dfn, ward_ien: ward_ien, at: at)
        end

        # --- Discharge (POST /movements/:id/discharge) ---------------------
        # BLOCKED: needs a FileMan-safe ^DIE/DGPMV* server RPC authored (see rpms-rpc#171 notes).
        def discharge(dfn, at:, disposition:)
          movement_blocked(:discharge, dfn: dfn, at: at, disposition: disposition)
        end

        # --- Cancel a movement (DELETE /movements/:id) ---------------------
        # BLOCKED: needs a FileMan-safe ^DIE/DGPMV* server RPC authored (see rpms-rpc#171 notes).
        def cancel_movement(movement_id)
          movement_blocked(:cancel, movement_id: movement_id)
        end

        # --- Admission movements (GET /patients/:dfn/movements) ------------
        # Confirmed read: RpmsRpc::Adt.admissions → ORWPT ADMITLST (^DGPM #405).
        def admissions(dfn)
          return validation_error("dfn is required") unless valid_id?(dfn)

          RpcSupport.with_broker(UNAVAILABLE) do
            { success: true, status: 200, admissions: RpmsRpc::Adt.admissions(dfn) }
          end
        end

        # --- Current inpatient location (GET /patients/:dfn/location) ------
        # Confirmed read: RpmsRpc::Adt.current_location → ORWPT INPLOC.
        def current_location(dfn)
          return validation_error("dfn is required") unless valid_id?(dfn)

          RpcSupport.with_broker(UNAVAILABLE) do
            location = RpmsRpc::Adt.current_location(dfn)
            { success: true, status: 200, current_location: location, admitted: !location.nil? }
          end
        end

        private

        # No stock movement-WRITE RPC exists (rpms-rpc#171). Report the write as
        # blocked (501) without pretending it dispatched; echo the attempted
        # movement so the caller/audit sees what was refused.
        def movement_blocked(kind, **attempted)
          { success: false, status: 501, kind: kind, error: BLOCKED_MESSAGE, attempted: attempted }
        end

        def valid_id?(value)
          !value.nil? && value.to_s.strip != "" && value.to_i.positive?
        end

        def validation_error(message)
          { success: false, status: 422, error: message }
        end
      end
    end
  end
end
