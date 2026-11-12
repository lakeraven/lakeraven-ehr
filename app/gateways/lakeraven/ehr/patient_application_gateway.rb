# frozen_string_literal: true

require "rpms_rpc/api/patient_application"

module Lakeraven
  module EHR
    # A patient's applications for coverage (rpms-ux S-REG-03.3 to 03.5): AG's
    # PATIENT APPLICATIONS (#9000045). RPMS has no registration call for them,
    # so RpmsRpc::PatientApplication files them the way AG's Benefits
    # Coordinator screens do, under AG's edit lock (openrpms#1053).
    #
    # Reads raise the gem's errors. Writes answer a Result: an error mid-call
    # is :unknown, because the write may already have filed.
    class PatientApplicationGateway
      Result = Data.define(:status, :message) do
        def saved? = status == :saved
        def unknown? = status == :unknown
      end

      class << self
        def types(via: ::RpmsRpc::PatientApplication) = via.types
        def for_patient(dfn, via: ::RpmsRpc::PatientApplication) = via.for_patient(dfn.to_i)

        # entry: an ApplicationEntry. The clerk who records it is the person
        # receiving it and the one who submitted it, as AG asks for both.
        def add(dfn, entry, duz:, via: ::RpmsRpc::PatientApplication)
          result_for(via.add(dfn.to_i, obtained: entry.applied_on, type: entry.type_ien.to_i,
                                       submitted: entry.submitted_on, via: entry.submitted_via.presence,
                                       received_by: duz_int(duz), submitted_by: duz_int(duz)))
        rescue ::RpmsRpc::Error, IOError, SystemCallError => e
          unknown(e)
        end

        def update_status(dfn, application, status, date, via: ::RpmsRpc::PatientApplication)
          result_for(via.update_status(dfn.to_i, application: application.to_i, status: status, date: date))
        rescue ::RpmsRpc::Error, IOError, SystemCallError => e
          unknown(e)
        end

        private

        def duz_int(duz) = duz.to_s.match?(/\A[1-9]\d*\z/) ? duz.to_i : nil

        def result_for(reply)
          return Result.new(status: :unknown, message: nil) if reply.nil?
          return Result.new(status: :saved, message: nil) if reply[:success]

          Result.new(status: :refused, message: reply[:message].to_s)
        end

        def unknown(error)
          Rails.logger.error("[registration] application write raised #{error.class}; the outcome is unknown")
          Result.new(status: :unknown, message: nil)
        end
      end
    end
  end
end
