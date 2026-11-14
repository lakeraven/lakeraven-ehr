# frozen_string_literal: true

require "rpms_rpc/api/patient"
require "rpms_rpc/api/registration"
require "rpms_rpc/api/ddr_fileman"

module Lakeraven
  module EHR
    # A registered patient's record, and the front desk's edits to it (rpms-ux
    # S-REG-20, S-REG-21), through RPMS's own registration package (AG):
    #
    # - the record is what AG's Personal Detail and Address windows show
    #   (RpmsRpc::Patient.registration_record, AGG BUILD WINDOW DISPLAY), with
    #   the email and cell phone from Patient.contact, which AG does not display;
    # - an edit is AG's own update (RpmsRpc::Patient.update, AGG UPDATE PATIENT
    #   under AG's edit lock), after AG's own field checks (AGG WINDOW DATA
    #   VALIDATION). When RPMS refuses, its message is passed on as it is.
    class PatientRecordGateway
      Result = Data.define(:status, :field, :message) do
        def saved? = status == :saved
        def refused? = status == :refused
        def outcome_unknown? = status == :unknown
        def partial? = status == :partial
      end

      def self.find(dfn, via: ::RpmsRpc::Patient)
        record = via.registration_record(dfn.to_i)
        return nil if record.nil?

        contact = via.contact(dfn.to_i) || {}
        record.merge(email: contact[:email], phone_cell: contact[:phone_cell])
      end

      # The choices for a pointer field, by name. Empty when RPMS lists nothing.
      def self.choices(attribute, via: ::RpmsRpc::Registration)
        Array(via.pick_list(attribute)).filter_map { |e| [ e[:name], e[:ien].to_s ] if e[:name].present? }
      end

      # CLASSIFICATION/BENEFICIARY (#9999999.25) entries, as [name, ien]
      # choices (#9000001 1111 points there). Empty when RPMS lists nothing.
      def self.classifications(via: ::RpmsRpc::DdrFileman)
        listing = via.lister(file: "9999999.25", fields: "@;.01", flags: "IP", xref: "B", max: "100")
        return [] if listing.nil? || listing[:error]

        listing[:entries].filter_map do |entry|
          name = Array(entry[:pieces]).first
          [ name, entry[:ien].to_s ] if name.present?
        end
      end

      # attrs: the RpmsRpc::Registration.update attributes to change.
      def self.update(dfn, attrs, via: ::RpmsRpc::Patient)
        return Result.new(status: :saved, field: nil, message: nil) if attrs.empty?

        result_for(via.update(dfn.to_i, **attrs))
      rescue ArgumentError => e
        Result.new(status: :refused, field: nil, message: e.message)
      rescue ::RpmsRpc::Error, IOError, SystemCallError => e
        # An error mid-call: a window may already be filed, so the outcome is
        # unknown, never "not saved".
        Rails.logger.error("[registration] patient update raised #{e.class}; the outcome is unknown")
        Result.new(status: :unknown, field: nil, message: nil)
      end

      # An address change that keeps the old address (S-REG-21.1): AG's
      # Address window, then the replaced address into PREVIOUS MAIL ADDRESSES
      # with the date the patient moved, under one AG edit lock
      # (RpmsRpc::Registration.change_address, openrpms#1055). attrs as for update.
      def self.change_address(dfn, attrs, moved_on:, via: ::RpmsRpc::Registration)
        return Result.new(status: :saved, field: nil, message: nil) if attrs.empty?

        result_for(via.change_address(dfn.to_i, moved_on: moved_on, **attrs))
      rescue ArgumentError => e
        Result.new(status: :refused, field: nil, message: e.message)
      rescue ::RpmsRpc::Error, IOError, SystemCallError => e
        Rails.logger.error("[registration] address change raised #{e.class}; the outcome is unknown")
        Result.new(status: :unknown, field: nil, message: nil)
      end

      # The addresses the patient used to live at, newest first (S-REG-21.1).
      # Raises the gem's errors when the list cannot be read.
      def self.address_history(dfn, via: ::RpmsRpc::Registration) = via.address_history(dfn.to_i)

      def self.result_for(reply)
        return Result.new(status: :unknown, field: nil, message: nil) if reply.nil?
        return Result.new(status: :saved, field: nil, message: nil) if reply[:success]
        # The address was filed and its history was not: RPMS's message says so.
        return Result.new(status: :partial, field: nil, message: reply[:message].to_s) if reply[:error] == :partial

        field = reply[:field].is_a?(Symbol) ? reply[:field] : nil
        message = case reply[:error]
        when :lock_failed then "Someone else is editing this patient. #{reply[:message]} Try again in a minute."
        when :validation_unavailable then "RPMS could not check this change, so nothing was saved. Try again."
        else reply[:message].to_s.presence || "RPMS did not save the change."
        end
        Result.new(status: :refused, field: field, message: message.strip)
      end
      private_class_method :result_for
    end
  end
end
