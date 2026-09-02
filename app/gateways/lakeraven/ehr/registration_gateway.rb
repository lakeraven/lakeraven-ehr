# frozen_string_literal: true

module Lakeraven
  module EHR
    # BPRM twin — registration group (scenarios #1, #2, #3, #4).
    #
    # Re-grounds BPRM's IRIS/BMW-SQL registration tier on the VistA RPC broker.
    # Target grounding: VAFC VOA ADD PATIENT (PATIENT #2 half) + the Lakeraven
    # LR* completion shim (IHS half — #9000001/HRN/tribe/community, AGADDREG as
    # reference; HRN clerk-supplied with AG1-faithful uniqueness) plus BMX
    # reads. The BHDPTRPC wire names below are UNVERIFIED PLACEHOLDERS with no
    # known server implementation anywhere (see rpms-rpc
    # docs/RPC_COVERAGE.md, "BHDPTRPC provenance"); they stay until the LR
    # shim lands so callers and tests don't churn. BPRM's original
    # SQL-MUTATE procs (AgPatientRegisterEvent, AgPatientUpdateEvent,
    # AgSetPatientInsuranceDelete) raw-write ^DPT/^AUPN*/insurance globals and
    # bypass FileMan cross-references + audit; here every write goes through a
    # FileMan-safe entry point so xrefs and the audit trail fire.
    #
    # See docs/BPRM_REG_SCHED_TWIN.md for the scenario→RPC mapping.
    class RegistrationGateway
      # PLACEHOLDER wire name — no server implementation on any known system
      # (never in any #8994 dump; the earlier "confirmed against the live
      # dump" claim here was wrong — see the header note). The first four
      # payload fields match the gem's RpmsRpc::Patient.registration_param
      # (NAME^SEX^DOB^SSN); the trailing IHS items are OUR contract extension.
      # Slated replacement: VAFC VOA ADD PATIENT + LR completion shim.
      REGISTER_RPC = "BHDPTRPC REGISTER"

      # PLACEHOLDER wire name — see header note. Slated: VAFCPTED + LR/AG path.
      UPDATE_RPC = "BHDPTRPC UPDATE"
      # PLACEHOLDER wire name — see header note.
      SEARCH_RPC = "BHDPTRPC LOOKUP"
      # PLACEHOLDER wire name — see header note.
      FACE_SHEET_RPC = "BHDPTRPC FACESHEET"
      # PLACEHOLDER wire name — see header note.
      INS_LIST_RPC = "BHDPTRPC INSLIST"
      # PLACEHOLDER wire name — see header note.
      INS_EDIT_RPC = "BHDPTRPC INSEDIT"
      # PLACEHOLDER wire name — see header note.
      INS_DELETE_RPC = "BHDPTRPC INSDELETE"

      # Field order for the REGISTER payload. Extends the existing rpms-rpc
      # NAME^SEX^DOB^SSN registration_param convention with the AG
      # registration items the twin captures.
      REGISTER_FIELDS = %i[name sex date_of_birth ssn tribe community classification eligibility].freeze
      DATE_FIELDS     = %i[date_of_birth date_of_death].freeze

      class << self
        # --- #1 Register a new patient (POST /patients) ---------------------
        # Target: VAFC VOA ADD PATIENT + LR completion shim → ^DPT/^AUPNPAT
        # (dispatches the placeholder REGISTER_RPC wire name until then).
        # TODO(sql-mutate→reimpl): BPRM's AgPatientRegisterEvent raw-inserts
        # ^DPT/^AUPN*; the AG REGISTER path must file via ^DIE/DBS so the .01
        # name xref, SSN xref, and registration audit fire.
        def register(params)
          params = params.to_h.transform_keys(&:to_sym)
          return validation_error("name is required") if blank?(params[:name])

          error = payload_error(REGISTER_FIELDS, params)
          return error if error

          RpcSupport.with_broker("Registration service unavailable") do
            raw = RpcSupport.broker.call_rpc(REGISTER_RPC, register_payload(params))
            parse_register(raw, params)
          end
        end

        # --- #2 Edit demographics (PATCH /patients/:dfn) -------------------
        # Target: VAFCPTED + LR/AG-faithful path → ^DIE on ^DPT (PATIENT #2)
        # (dispatches the placeholder UPDATE_RPC wire name until then).
        # TODO(sql-mutate→reimpl): BPRM patches individual ^DPT fields raw
        # (AgSetCorrectPatientName/CellNumber/DateOfDeath/Mbi). File each
        # through ^DIE so the FileMan audit (DD "AUDIT") records the change.
        def update(dfn, changes)
          changes = changes.to_h.transform_keys(&:to_sym)
          return validation_error("dfn is required") unless valid_id?(dfn)
          return validation_error("no changes given") if changes.empty?

          error = payload_error(changes.keys, changes)
          return error if error

          RpcSupport.with_broker("Registration service unavailable") do
            raw = RpcSupport.broker.call_rpc(UPDATE_RPC, dfn.to_s, update_payload(changes))
            parse_update(raw, dfn, changes)
          end
        end

        # --- #4 Search (GET /patients?q=) ----------------------------------
        # PROVISIONAL: AG search re-expressed via BMX; DOB narrows the match
        # in-gateway. RPC name/encoding unconfirmed against #8994 — the
        # confirmed stock search is ORWPT LIST ALL (RpmsRpc::Patient.search).
        def search(query, dob: nil)
          RpcSupport.with_broker("Patient lookup service unavailable") do
            raw = RpcSupport.broker.call_rpc(SEARCH_RPC, query.to_s)
            patients = RpcSupport.lines(raw).filter_map { |line| parse_search_row(line) }
            patients = filter_by_dob(patients, dob) if dob
            { success: true, status: 200, patients: patients }
          end
        end

        # --- #4 Face sheet (GET /patients/:dfn/face_sheet) -----------------
        # AgGetPatientFaceSheet + AgGetPatientErrorsAndWarnings (read).
        def face_sheet(dfn)
          return validation_error("dfn is required") unless valid_id?(dfn)

          RpcSupport.with_broker("Patient lookup service unavailable") do
            parts = RpcSupport.pieces(RpcSupport.broker.call_rpc(FACE_SHEET_RPC, dfn.to_s))
            return { success: false, status: 404, error: "Patient not found" } if parts[0].to_s.empty?

            { success: true, status: 200, face_sheet: face_sheet_hash(parts), warnings: warning_items(parts[3]) }
          end
        end

        # --- #3 List insurances (GET /patients/:dfn/insurances) ------------
        def insurances(dfn)
          return validation_error("dfn is required") unless valid_id?(dfn)

          RpcSupport.with_broker("Insurance service unavailable") do
            raw = RpcSupport.broker.call_rpc(INS_LIST_RPC, dfn.to_s)
            { success: true, status: 200, insurances: RpcSupport.lines(raw).filter_map { |l| parse_insurance(l) } }
          end
        end

        # --- #3 Update a policy number (PATCH /patients/:dfn/insurances/:id) -
        # TODO(sql-mutate→reimpl): file the policy-number change through ^DIE
        # on the patient-insurance multiple rather than a raw UPDATE.
        def update_insurance(dfn, insurance_id, policy_number:)
          return validation_error("dfn is required") unless valid_id?(dfn)
          return validation_error("insurance id is required") unless valid_id?(insurance_id)
          if RpcSupport.unsafe_field?(policy_number)
            return validation_error("policy number contains unsupported characters")
          end

          RpcSupport.with_broker("Insurance service unavailable") do
            payload = [ dfn, insurance_id, policy_number ].map(&:to_s).join("^")
            parts = RpcSupport.pieces(RpcSupport.broker.call_rpc(INS_EDIT_RPC, dfn.to_s, payload))
            next RpcSupport.rejection(parts[1]) unless RpcSupport.success_flag?(parts)

            { success: true, status: 200, insurance_id: insurance_id.to_i, policy_number: policy_number }
          end
        end

        # --- #3 Delete an insurance + safe cascade (DELETE …/insurances/:id) -
        # The highest-risk audit-gap item. BPRM's AgSetPatientInsuranceDelete
        # is a dynamic-SQL 7-table cascade DELETE that bypasses FileMan.
        # TODO(sql-mutate→reimpl): replace with a ^DIE/DBS transaction that
        # walks the dependent coverage/eligibility multiples and files each
        # deletion so cross-references are cleaned and the audit fires. An
        # in-use policy must be refused (409) before any dependent row is
        # touched.
        def delete_insurance(dfn, insurance_id)
          return validation_error("dfn is required") unless valid_id?(dfn)
          return validation_error("insurance id is required") unless valid_id?(insurance_id)

          RpcSupport.with_broker("Insurance service unavailable") do
            guard = in_use_guard(dfn, insurance_id)
            next guard if guard

            parts = RpcSupport.pieces(RpcSupport.broker.call_rpc(INS_DELETE_RPC, dfn.to_s, insurance_id.to_s))
            next RpcSupport.rejection(parts[1]) unless RpcSupport.success_flag?(parts)

            { success: true, status: 200, insurance_id: insurance_id.to_i, cascade: :fileman }
          end
        end

        private

        def register_payload(params)
          REGISTER_FIELDS.map { |f| encode_field(f, params[f]) }.join("^")
        end

        def update_payload(changes)
          changes.map { |field, value| "#{field}=#{encode_field(field, value)}" }.join("^")
        end

        # encode_field assumes payload_error has already vetted the values:
        # date fields Date.parse cleanly, and free text carries no ^/control
        # characters that would shift downstream $PIECE parsing.
        def encode_field(field, value)
          return "" if value.nil?
          return RpcSupport.fm_date(value) if DATE_FIELDS.include?(field)

          value.to_s
        end

        # Pre-flight the caret payload: reject (422) anything that cannot be
        # encoded safely rather than emit it raw. Covers BPRM's caret-injection
        # seam (a ^/newline in policy numbers, names, AG free text corrupts
        # every downstream field) and unparseable dates (which would otherwise
        # raise past with_broker as a 500). Field names are checked too — on
        # the update path they are caller-supplied and caret-joined.
        def payload_error(fields, values)
          fields.each do |field|
            return validation_error("field names contain unsupported characters") if RpcSupport.unsafe_field?(field)

            value = values[field]
            next if value.nil?

            if DATE_FIELDS.include?(field)
              return validation_error("#{field} is not a valid date") unless RpcSupport.valid_fm_date?(value)
            elsif RpcSupport.unsafe_field?(value)
              return validation_error("#{field} contains unsupported characters")
            end
          end
          nil
        end

        def parse_register(raw, params)
          parts = RpcSupport.pieces(raw)
          return RpcSupport.rejection(parts[1] || "Registration rejected") unless RpcSupport.success_flag?(parts)

          {
            success: true, status: 201, dfn: parts[1].to_i,
            name: params[:name], warnings: warning_items(parts[2])
          }
        end

        def parse_update(raw, dfn, changes)
          parts = RpcSupport.pieces(raw)
          return RpcSupport.rejection(parts[1] || "Update rejected") unless RpcSupport.success_flag?(parts)

          { success: true, status: 200, dfn: dfn.to_i, updated: changes }
        end

        # Fail-CLOSED guard for the cascade delete: the delete may proceed
        # only when the INSLIST read POSITIVELY confirms the target policy
        # exists and is not in use. A failed read (503/transient), a
        # malformed row, or a target absent from the listing all mean
        # "cannot confirm not-in-use" and refuse the delete with 409 —
        # never "safe to delete".
        def in_use_guard(dfn, insurance_id)
          listing = insurances(dfn)
          return cannot_confirm_delete unless listing[:success]

          target = listing[:insurances].find { |i| i[:id] == insurance_id.to_i }
          return cannot_confirm_delete if target.nil?
          return nil unless target[:in_use]

          { success: false, status: 409, error: "Insurance is in use and cannot be deleted" }
        end

        def cannot_confirm_delete
          { success: false, status: 409,
            error: "Cannot confirm the insurance is not in use; delete refused" }
        end

        def parse_search_row(line)
          parts = line.to_s.split("^", -1)
          return nil if parts[0].to_s.empty?

          { dfn: parts[0].to_i, name: parts[1], dob: RpmsRpc::FilemanDateParser.parse_date(parts[2]), sex: parts[3] }
        end

        def filter_by_dob(patients, dob)
          wanted = Date.parse(dob.to_s)
          patients.select { |p| p[:dob] == wanted }
        rescue ArgumentError
          patients
        end

        def parse_insurance(line)
          parts = line.to_s.split("^", -1)
          return nil if parts[0].to_s.empty?

          {
            id: parts[0].to_i, payer: parts[1], policy_no: parts[2],
            type: parts[3], in_use: parts[4].to_s == "1"
          }
        end

        def face_sheet_hash(parts)
          { name: parts[0], community: parts[1], tribe: parts[2] }
        end

        # Incomplete-registration items arrive as a semicolon-delimited list
        # of field names (e.g. "COMMUNITY;ELIGIBILITY").
        def warning_items(piece)
          piece.to_s.split(";").map(&:strip).reject(&:empty?)
        end

        def valid_id?(value)
          !value.nil? && value.to_s.strip != "" && value.to_i.positive?
        end

        def blank?(value)
          value.nil? || value.to_s.strip.empty?
        end

        def validation_error(message)
          { success: false, status: 422, error: message }
        end
      end
    end
  end
end
