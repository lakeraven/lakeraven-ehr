# frozen_string_literal: true

require "time"
require "date"
require "rpms_rpc/client"
require "rpms_rpc/fileman_date_parser"

module Lakeraven
  module EHR
    # Shared helpers for the BPRM registration/scheduling/ADT twin gateways.
    #
    # Every reg/sched gateway follows the same shape: build a caret-delimited
    # payload, call one (or a few) RPMS RPCs through RpmsRpc.client, parse the
    # caret response, and return a transport-neutral result Hash carrying an
    # HTTP :status so a thin controller can render it directly.
    #
    # Response convention for write RPCs (BSDX / DG* / the placeholder
    # BHDPTRPC wire names — see RegistrationGateway's header note): the first
    # caret piece is a success flag ("1"/"0"); on failure the human-readable
    # M-side message follows. Reads return an Array of caret-delimited lines.
    module RpcSupport
      module_function

      # The configured broker (real BmxClient/CiaClient in production, a mock
      # or FakeBroker in tests). Kept behind a helper so gateways never reach
      # for RpmsRpc.client directly.
      def broker
        RpmsRpc.client
      end

      # Run a broker interaction, translating a broker-unreachable condition
      # (socket/timeout) into a 503 result rather than letting it bubble as a
      # data error — mirrors the PatientGateway.register contract in the doc.
      def with_broker(unavailable_message)
        yield
      rescue RpmsRpc::Client::ConnectionError => e
        Rails.logger.warn("RPMS broker unreachable: #{PhiSanitizer.sanitize_message(e.message)}") if defined?(Rails)
        { success: false, status: 503, error: unavailable_message }
      end

      # Split a single caret-delimited response line into pieces. Accepts the
      # raw String or an Array (uses the first line), never raising on nil.
      def pieces(raw)
        line = raw.is_a?(Array) ? raw.first : raw
        line.to_s.split("^", -1)
      end

      # Normalize a response into an Array of lines for multi-record reads.
      def lines(raw)
        return raw if raw.is_a?(Array)
        return [] if raw.nil? || raw.to_s.empty?

        [ raw.to_s ]
      end

      def success_flag?(parts)
        parts[0].to_s.strip == "1"
      end

      # FileMan internal datetime from an ISO-8601 string ("2026-08-20 09:00").
      def fm_datetime(iso)
        return "" if iso.nil? || iso.to_s.empty?

        RpmsRpc::FilemanDateParser.format_datetime(Time.parse(iso.to_s))
      end

      # FileMan internal date from an ISO-8601 date string ("1992-03-11").
      def fm_date(iso)
        return "" if iso.nil? || iso.to_s.empty?

        RpmsRpc::FilemanDateParser.format_date(Date.parse(iso.to_s))
      end

      def sanitize(message)
        PhiSanitizer.sanitize_message(message.to_s)
      end

      # Characters that must never be embedded in a caret-joined RPC payload
      # field: the ^ delimiter itself plus CR/LF/control characters. Any of
      # them would shift every downstream $PIECE on the M side, silently
      # corrupting the record — so gateways REJECT such input (422) rather
      # than escape it (no escaping convention exists on the M side).
      UNSAFE_FIELD_PATTERN = /[\^\x00-\x1F\x7F]/

      def unsafe_field?(value)
        value.to_s.match?(UNSAFE_FIELD_PATTERN)
      end

      # True when the value can be safely fed to fm_date (nil/empty encodes
      # to "" and is allowed; anything else must Date.parse). Write-path
      # gateways use this to return a 422 up front instead of letting
      # Date.parse raise mid-broker-call and escape as a 500 (with_broker
      # only rescues ConnectionError).
      def valid_fm_date?(value)
        return true if value.nil? || value.to_s.empty?

        Date.parse(value.to_s)
        true
      rescue ArgumentError, TypeError
        false
      end

      # Map an M-side rejection message onto an HTTP status. Conflicts
      # (locks, occupied slots, in-use records) are 409; everything else that
      # the broker rejected is a 422 unprocessable-entity.
      CONFLICT_PATTERN = /
        not\ available | already\ booked | occupied |
        another\ user | locked | in\ use
      /xi

      def rejection_status(message)
        message.to_s.match?(CONFLICT_PATTERN) ? 409 : 422
      end

      # Standard rejection result for a write whose broker call returned "0^…".
      def rejection(message, status: nil)
        msg = sanitize(message)
        { success: false, status: status || rejection_status(msg), error: msg }
      end
    end
  end
end
