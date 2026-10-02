# frozen_string_literal: true

require "rpms_rpc/api/registration"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/tribal"

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
        # broker gave no answer. The gem's own listing (DDR LISTER over
        # #9999999.03 by the B index); one page, the first `part` of names
        # when given.
        def tribes(part: nil)
          RpmsRpc::Tribal.tribes(part: part)
        end

        # Patients already on file with the same name, date of birth and sex
        # (S-REG-02.3): the stock name lookup (ORWPT LIST ALL), narrowed here.
        def possible_matches(name:, dob:, sex:)
          last = name.to_s.split(",").first.to_s.strip
          return [] if last.empty?

          Patient.search(last).select do |p|
            p.name.to_s.casecmp?(name.to_s.strip) && p.dob == dob && p.sex.to_s.casecmp?(sex.to_s)
          end
        end

        # Is this social security number already on another patient in
        # PATIENT (#2)? (S-REG-02.8) The stock SSN lookup; nil means the
        # broker gave no answer, which the caller treats as "cannot tell".
        def ssn_taken?(ssn)
          Patient.search_by_ssn(ssn).any?
        end

        # File a health record number for the patient at a facility
        # (S-REG-06.1): an entry in the HEALTH RECORD multiple (#9000001.41)
        # DINUM'd to the facility, .01 the facility pointer, .02 the number,
        # through DDR FILER under the ^AUPNPAT(DFN) lock, the rows exactly as
        # RpmsRpc::Registration files them on a new registration
        # (completion_rows: AG1.m:53-54, AGACT.m:10). Returns { success: true }
        # or { success: false, status:, error: }.
        def file_hrn(dfn:, facility_ien:, hrn:)
          node = "^AUPNPAT(#{dfn})"
          RpcSupport.with_broker(UNAVAILABLE) do
            next { success: false, status: 409, error: "The patient's record is locked by another user" } unless RpmsRpc::DdrFileman.lock(node: node)

            begin
              sub_iens = "+1,#{dfn},"
              filed = RpmsRpc::DdrFileman.filer(mode: "ADD", rows: [
                { file: HRN_SUBFILE, field: ".01", iens: sub_iens, value: facility_ien.to_s },
                { file: HRN_SUBFILE, field: HRN_FIELD, iens: sub_iens, value: hrn.to_s }
              ], iens: { 1 => facility_ien.to_s })
              next unavailable if filed.nil?
              next { success: false, status: 422, error: filed[:errors].join("; ") } unless filed[:success]

              { success: true }
            ensure
              RpmsRpc::DdrFileman.unlock(node: node)
            end
          end
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
