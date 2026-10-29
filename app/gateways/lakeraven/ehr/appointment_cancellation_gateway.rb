# frozen_string_literal: true

require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/scheduling"

module Lakeraven
  module EHR
    # Cancelling an appointment (rpms-ux S-SCH-02) through BSDX CANCEL APPOINTMENT
    # (RpmsRpc::Scheduling.cancel_appointment). Live on a built image the server
    # refuses only a checked-in appointment; it files a second cancellation of a
    # cancelled one and a patient-only reason on a clinic cancellation. So which
    # reasons a cancellation may file, and whether the appointment can be
    # cancelled at all, are decided here from what RPMS holds.
    class AppointmentCancellationGateway
      Result = Data.define(:status, :message) do
        def cancelled? = status == :cancelled
      end

      # CANCELLATION REASONS (#409.2): .01 NAME, 2 TYPE (P patient, C clinic,
      # B both), 4 INACTIVE. Read with DDR LISTER, which runs in the sign-on
      # context (BSDXRPC does not carry it).
      REASON_FILE = "409.2"
      WHO_TYPES = { "C" => %w[C B], "PC" => %w[P B] }.freeze

      # The active reasons a cancellation by whom ("C" clinic, "PC" patient) may file.
      def self.reasons(whom, via: ::RpmsRpc::DdrFileman)
        allowed = WHO_TYPES.fetch(whom.to_s, [])
        listing = via.lister(file: REASON_FILE, fields: "@;.01;2I;4I", xref: "B")
        return [] if listing.nil? || listing[:error]

        listing[:entries].filter_map do |entry|
          name, type, inactive = entry[:pieces]
          next if inactive.to_s == "1" || !allowed.include?(type.to_s)

          { ien: entry[:ien].to_i, name: name }
        end
      end

      def self.cancel(appointment_id, whom:, reason_ien:, remarks:, via: ::RpmsRpc::Scheduling)
        reply = via.cancel_appointment(appointment_id, reason: reason_ien, type: whom, note: remarks)
        return Result.new(status: :unknown, message: nil) if reply.nil?
        return Result.new(status: :cancelled, message: nil) if reply[:success]

        Result.new(status: :refused, message: reply[:error].to_s)
      rescue ::RpmsRpc::Client::RpcError, ::RpmsRpc::Client::ConnectionError, IOError, SystemCallError => e
        Rails.logger.error("[scheduling] cancel raised #{e.class}; the outcome is unknown")
        Result.new(status: :unknown, message: nil)
      end
    end
  end
end
