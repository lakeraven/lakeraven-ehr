# frozen_string_literal: true

require "rpms_rpc/api/registration"
require "rpms_rpc/api/ddr_fileman"

module Lakeraven
  module EHR
    # The front desk's registration path (rpms-ux W01, lakeraven-ehr#565).
    #
    # Thin over the gem: RpmsRpc::Registration owns the wire contracts and
    # picks the lineage per broker. On RPMS it delegates to the AG package's
    # GUI RPCs (AGG ADD NEW PATIENT files PATIENT #2 and IHS PATIENT
    # #9000001, then AGG UPDATE PATIENT files the HRN into the 41-multiple,
    # HRN := DFN); on a broker with no AG it composes VAFC VOA ADD PATIENT +
    # DDR FILER, which needs VA elements (station number, ICN) that no IHS
    # clerk has, so that case is refused here rather than guessed at.
    #
    # The AG "Mini Registration" window carries name, sex, DOB and SSN only,
    # so the IHS fields the front desk also records (tribe of membership
    # #9000001/1108, current community #9000001/1118) are filed afterwards
    # through RpmsRpc::Registration.update (DDR FILER, FILE^DIE under the
    # ^DPT(DFN) lock). A registration whose completion fails is still a
    # registration: the result says so instead of hiding it.
    #
    # RegistrationGateway (the JSON API's placeholder-RPC path) is left as it
    # is; this is the browser's.
    class PatientRegistrationGateway
      UNAVAILABLE = "Registration service unavailable"
      # TRIBE (^AUTTTRI), the file #9000001/1108 points to; .01 NAME.
      TRIBE_FILE = "9999999.03"
      HRN_SUBFILE = RpmsRpc::Registration::HRN_SUBFILE
      HRN_FIELD = RpmsRpc::Registration::HRN_FIELD
      FIELD_TRIBE = RpmsRpc::Registration::FIELD_TRIBE
      FIELD_COMMUNITY = RpmsRpc::Registration::FIELD_COMMUNITY

      class << self
        # attrs: name "LAST,FIRST", sex "M"/"F", dob Date, ssn (optional),
        # tribe_ien (pointer IEN into TRIBE #9999999.03), community (text).
        #
        # Returns { success: true, dfn:, hrn:, completion: :filed | :failed,
        # warnings: [] } or { success: false, status:, error: }.
        def register(attrs)
          RpcSupport.with_broker(UNAVAILABLE) do
            created = RpmsRpc::Registration.register(
              name: attrs[:name], sex: attrs[:sex], dob: attrs[:dob], ssn: attrs[:ssn]
            )
            next unavailable if created.nil?
            next rejected(created) unless created[:success]

            completed(created[:dfn], attrs)
          end
        rescue ArgumentError => e
          # The composition lineage asked for a VA element (station number,
          # ICN, veteran status); this broker has no AG registration.
          { success: false, status: 503,
            error: "This RPMS has no AG registration service, and the engine cannot register without it (#{e.message})" }
        end

        # TRIBE entries for a picker: [{ ien:, name: }], or nil when the
        # broker gave no answer. DDR LISTER over #9999999.03 with the .01
        # name; the packed row's first piece after the IEN is read as the
        # name (no live capture of this listing yet).
        def tribes
          listed = RpmsRpc::DdrFileman.lister(file: TRIBE_FILE, fields: ".01", max: "*")
          return nil if listed.nil? || listed[:error]

          listed[:entries].map { |e| { ien: e[:ien], name: e[:pieces].first.to_s } }
        end

        # The patient's health record number at a facility: field .02 of the
        # HEALTH RECORD multiple (#9000001.41), whose entry is DINUM'd to the
        # facility IEN. nil when none is on file or the broker gave no answer.
        def hrn(dfn, facility_ien)
          return nil if dfn.to_i <= 0 || facility_ien.to_i <= 0

          read = RpmsRpc::DdrFileman.gets_entry(file: HRN_SUBFILE, iens: "#{facility_ien},#{dfn},", fields: HRN_FIELD)
          return nil if read.nil? || read[:error]

          read[:fields].dig(HRN_FIELD, :external).presence
        end

        private

        def completed(dfn, attrs)
          fields = {}
          fields[FIELD_TRIBE] = attrs[:tribe_ien].to_s if attrs[:tribe_ien].present?
          fields[FIELD_COMMUNITY] = attrs[:community].to_s if attrs[:community].present?
          result = { success: true, dfn: dfn.to_i, hrn: dfn.to_s, completion: :filed, warnings: [] }
          return result if fields.empty?

          filed = RpmsRpc::Registration.update(dfn, ihs_fields: fields)
          return result if filed && filed[:success]

          message = filed ? filed[:message].to_s : "no response from the broker"
          result.merge(completion: :failed,
                       warnings: [ "Tribe and community were not filed (#{message}); record them on the registration." ])
        end

        def unavailable
          { success: false, status: 503, error: UNAVAILABLE }
        end

        def rejected(created)
          { success: false, status: RpcSupport.rejection_status(created[:message]),
            error: created[:message].presence || "Registration rejected (#{created[:error]})" }
        end
      end
    end
  end
end
