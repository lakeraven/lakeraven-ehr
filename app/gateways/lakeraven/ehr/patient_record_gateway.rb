# frozen_string_literal: true

require "rpms_rpc/api/patient"
require "rpms_rpc/api/registration"

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

      def self.result_for(reply)
        return Result.new(status: :unknown, field: nil, message: nil) if reply.nil?
        return Result.new(status: :saved, field: nil, message: nil) if reply[:success]

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
