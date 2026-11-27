# frozen_string_literal: true

require "digest"

module Lakeraven
  module EHR
    # Creates a TIU progress note against an open encounter, writes its
    # text, and signs it. Signing validates the user's electronic signature
    # code before any sign action reaches the record — an invalid code
    # never touches the note.
    #
    # 42 CFR Part 2 (#906, slice of #522): substance-use content in a note is
    # LABELLED, never blocked. Once the gateway has given the note its IEN,
    # and before the text is written, text that SudContentSuspicion reads as
    # :suspected or :unclassified gets a Part2Label row. A failed label write
    # does not stop the note (part2_label is :label_failed, on the Result and
    # on the instance); the controller records it in the note submission's
    # audit row, and read-time Part2Posture still treats an unlabelled
    # suspected note as Part 2.
    #
    # ESignatureGateway.validate answers what RpmsRpc::ESignature.validate
    # answers: true when RPMS accepts the code, false when it does not. Only
    # true is an accepted code. Any other answer (nil, a hash, a string) is a
    # gateway error, never an acceptance.
    #
    # The chart's flow (create_and_sign) also asks TIU which signing action
    # the author holds on the new note (ESignatureGateway.which_action) and
    # signs only when the answer is :sign. Its audit row is written by
    # ProgressNotesController, by what the submission did.
    #
    # Every #sign call writes exactly one append-only AuditEvent (#960), on
    # every path, including a gateway that raises (the row is written, then
    # the same exception is re-raised). The signature code, the note text
    # and exception messages never reach the row.
    #
    # On success the row holds two SHA-256 hashes of note BODY rows, as
    # ProgressNoteGateway.fetch_body returns them, each joined with "\n" and
    # followed by its row count. content-sha256 is of the body read before
    # the sign action: what was signed. record-sha256 is of ALL the body
    # rows read again after it, signature block included: the note as filed.
    # The filed record must begin with exactly the signed rows; if it does
    # not, the row still records the signature and ends "record-sha256
    # mismatch", which never verifies. A verifier re-reads the body and needs
    # an exact match of the hash of all its rows with record-sha256, so an
    # appended, removed or edited row shows (trailing blank rows only as far
    # as the transport delivers them; CIA drops them, see
    # ProgressNoteGateway.fetch_body); a record mismatch means the note
    # changed since filing. Comparing content-sha256 with the hash of the
    # first content-rows rows tells an append from an edit. If that post-sign
    # read fails, the row still records the signature and ends
    # "record-sha256 unavailable", which never verifies.
    # The TIU header is not covered by either hash. Both hashes are written
    # for #sign only; the chart's create_and_sign path is audited by
    # ProgressNotesController without them.
    #
    # It fails closed: a row that cannot be written raises. The residual: if
    # the success row fails after the sign action, the RPMS signature stands
    # and the exception surfaces to the caller.
    class ProgressNoteService
      PART2_RECORD_TYPE = Part2Label::TIU_NOTE

      # Serious failures ("8"): gateway errors, raised gateway calls and a
      # sign whose outcome is unknown. Every other refusal is minor ("4").
      SERIOUS_REASONS = %i[gateway_error gateway_exception sign_outcome_unknown].freeze
      # The only AuditContext attributes that reach the row.
      AGENT_ATTRIBUTES = %i[agent_who_type agent_who_identifier agent_name].freeze

      # stage names the step a failure happened at: :signature_check (nothing
      # written), :create (no note), :text (a note may exist without its
      # text), :sign_action (the note and its text are saved, unsigned: TIU
      # did not answer that the author may sign it), or :sign (the note and
      # its text are saved, unsigned).
      Result = Struct.new(:success, :note_ien, :error, :raw, :stage, :part2_label, keyword_init: true) do
        def success? = success
      end

      # Gateways are constructor-injected so tests can pass explicit fakes
      # without mutating shared global state. Defaults are the production
      # gateways.
      def initialize(dfn:, visit_ien:, author_duz:,
                     gateway: ProgressNoteGateway, esignature_gateway: ESignatureGateway)
        @dfn = dfn
        @visit_ien = visit_ien
        @author_duz = author_duz
        @gateway = gateway
        @esignature_gateway = esignature_gateway
        @write_sent = false
      end

      # The note created by this service, once TIU answered with its IEN.
      attr_reader :created_note_ien

      # The Part 2 label outcome of create (:labelled, :not_suspected or
      # :label_failed): nil before create labels anything, and set as soon
      # as the label step returns, before the text is written, so a later
      # step that raises does not lose it.
      attr_reader :part2_label

      # Whether a TIU write (note creation) has been sent. Once it has, a
      # raised call leaves the chart in an unknown state.
      def write_sent? = @write_sent

      def create(title_ien:, text:)
        return failure(:invalid_input, stage: :create) if @dfn.nil? || @visit_ien.nil?
        return failure(:missing_title, stage: :create) if title_ien.nil?

        @write_sent = true
        created = @gateway.create(@dfn, @visit_ien, title_ien)
        return failure(:gateway_error, raw: created, stage: :create) unless created.is_a?(Hash) && created[:success]

        note_ien = created[:ien]
        @created_note_ien = note_ien
        part2_label = @part2_label = label_part2(note_ien, text)

        written = @gateway.update_text(note_ien, text)
        unless written.is_a?(Hash) && written[:success]
          return failure(:gateway_error, raw: written, stage: :text, note_ien: note_ien, part2_label: part2_label)
        end

        Result.new(success: true, note_ien: note_ien, raw: written, part2_label: part2_label)
      end

      # Whether RPMS accepts the author's signature code, asked before
      # anything is written. A success Result when it answers true;
      # :invalid_signature_code when it answers false; :gateway_error for any
      # other answer.
      def check_signature_code(signature_code)
        validation = @esignature_gateway.validate(@author_duz, signature_code)
        return Result.new(success: true) if validation == true
        return failure(:invalid_signature_code, stage: :signature_check) if validation == false

        failure(:gateway_error, raw: validation, stage: :signature_check)
      end

      def signature_code_accepted?(signature_code)
        check_signature_code(signature_code).success?
      end

      # Signs an existing note, writing one audit row (#960) on every path.
      def sign(note_ien:, signature_code:)
        agent = sign_agent
        note_id = identifier(note_ien)
        return refuse_sign!(note_id, :invalid_input, agent: agent, stage: :sign) if identifier(@dfn).nil?
        return refuse_sign!(nil, :no_note, agent: agent, stage: :sign) if note_ien.nil?
        return refuse_sign!(nil, :invalid_input, agent: agent, stage: :sign) if note_id.nil?
        return refuse_sign!(note_id, :invalid_input, agent: agent, stage: :sign) if identifier(@author_duz).nil?
        return refuse_sign!(note_id, :actor_mismatch, agent: agent, stage: :sign) unless author_agent?(agent)

        checked = audit_exception(note_id, :gateway_exception, agent: agent) do
          check_signature_code(signature_code)
        end
        unless checked.success?
          return refuse_sign!(note_id, checked.error, agent: agent, raw: checked.raw, stage: checked.stage)
        end

        # We never sign what we cannot hash, and an empty body never verifies.
        rows = audit_exception(note_id, :gateway_exception, agent: agent) { @gateway.fetch_body(note_ien) }
        return refuse_sign!(note_id, :note_text_unavailable, agent: agent, stage: :sign) unless body_rows?(rows)

        # The RPC may have filed before it raised, so the row does not claim
        # the note is unsigned.
        raw = audit_exception(note_id, :sign_outcome_unknown, agent: agent) do
          @esignature_gateway.add(note_ien, @author_duz, signature_code, action: :sign)
        end
        unless raw.is_a?(Hash) && raw[:success]
          return refuse_sign!(note_id, :gateway_error, agent: agent, raw: raw, stage: :sign, note_ien: note_ien)
        end

        record_sign_audit!(note_id, outcome: "0", agent: agent,
                           desc: "progress_note_signed; patient #{@dfn}; " \
                                 "content-sha256 #{body_digest(rows)}; content-rows #{rows.size}; " \
                                 "#{filed_record(note_ien, rows)}")
        Result.new(success: true, note_ien: note_ien, raw: raw)
      end

      # The chart's flow: the code is checked first, so a code RPMS does not
      # accept creates no note. Then the note is created and its text
      # written. TIU is asked which signing action the author holds on it,
      # and only :sign signs it, with the code just checked. Any other answer
      # (:cosign, nil) leaves the note saved unsigned, and the code is not
      # sent. Every Result once the note exists carries the part2_label
      # create computed, and the instance's part2_label keeps it even when a
      # later step raises; ProgressNotesController records a :label_failed
      # in the note submission's audit row ("part 2 label failed").
      def create_and_sign(title_ien:, text:, signature_code:)
        checked = check_signature_code(signature_code)
        return checked unless checked.success?

        created = create(title_ien: title_ien, text: text)
        return created unless created.success?

        note_ien = created.note_ien
        part2_label = created.part2_label
        action = @esignature_gateway.which_action(note_ien, @author_duz)
        unless action == :sign
          return failure(:sign_not_permitted, stage: :sign_action, note_ien: note_ien, part2_label: part2_label)
        end

        add_signature(note_ien, signature_code, part2_label: part2_label)
      end

      private

      # Labels before the text is written, so the label never trails the
      # content. classify never raises (blank or unreadable text is
      # :unclassified and labelled). A note the gateway gave no IEN cannot be
      # labelled, so it is never reported as :labelled. Only database errors
      # are rescued: the note must not be blocked by a label write, and
      # Part2Posture fails closed for it. The failure is logged so the gap
      # can be found and repaired: the error class and the note IEN only,
      # never the note text or the exception message (which can carry SQL
      # with bound values).
      def label_part2(note_ien, text)
        return :not_suspected if SudContentSuspicion.classify(text) == :not_suspected
        return :label_failed if note_ien.to_s.blank?

        Part2Label.mark!(patient_dfn: @dfn.to_s, record_type: PART2_RECORD_TYPE, record_id: note_ien.to_s)
        :labelled
      rescue ActiveRecord::ActiveRecordError => e
        Rails.logger.warn("Part 2 label write failed (#{e.class.name}) for tiu note #{note_ien}")
        :label_failed
      end

      # part2_label is passed through to the Result unchanged; sign leaves it
      # nil because it labels nothing.
      def add_signature(note_ien, signature_code, part2_label: nil)
        raw = @esignature_gateway.add(note_ien, @author_duz, signature_code, action: :sign)
        unless raw.is_a?(Hash) && raw[:success]
          return failure(:gateway_error, raw: raw, stage: :sign, note_ien: note_ien, part2_label: part2_label)
        end

        Result.new(success: true, note_ien: note_ien, raw: raw, part2_label: part2_label)
      end

      # The value as a String when it is all digits, else nil, so a
      # malformed identifier never reaches the row.
      def identifier(value)
        id = value.to_s
        id.match?(AuditEvent::PATIENT_IDENTIFIER_PATTERN) ? id : nil
      end

      # The attributed identity when AuditContext has one. Unattributed, the
      # author is assumed only outside an audited request and only when the
      # author is a DUZ; otherwise the agent stays Unknown.
      def sign_agent
        attributed = AuditContext.agent_attributes.slice(*AGENT_ATTRIBUTES)
        return attributed unless attributed[:agent_who_identifier].nil?
        return attributed if AuditContext.inside_audited_request? || identifier(@author_duz).nil?

        { agent_who_type: "Practitioner", agent_who_identifier: @author_duz.to_s }
      end

      def author_agent?(agent)
        agent[:agent_who_type] == "Practitioner" && agent[:agent_who_identifier].to_s == @author_duz.to_s
      end

      # A row must be a String of valid encoding; a row holding CR or LF
      # would make the "\n" join ambiguous.
      def body_rows?(rows)
        rows.is_a?(Array) && rows.all? { |row| body_row?(row) } && rows.any?(&:present?)
      end

      def body_row?(row)
        row.is_a?(String) && row.valid_encoding? && !row.match?(/[\r\n]/)
      end

      def body_digest(rows) = Digest::SHA256.hexdigest(rows.join("\n"))

      # The note as filed, read again after the sign action. The signature
      # already happened, so a read that fails or returns no valid body is
      # recorded as unavailable rather than raised; its message is never
      # written. A filed body that does not begin with the signed rows is a
      # mismatch.
      def filed_record(note_ien, signed)
        rows = @gateway.fetch_body(note_ien)
        return "record-sha256 unavailable" unless body_rows?(rows)
        return "record-sha256 mismatch" unless rows.first(signed.size) == signed

        "record-sha256 #{body_digest(rows)}; record-rows #{rows.size}"
      rescue StandardError, NotImplementedError => e
        Rails.logger.error("[audit] could not re-read a signed note body: #{e.class.name}")
        "record-sha256 unavailable"
      end

      # A gateway that raises (NotImplementedError too: RpmsRpc::BmxClient
      # raises it) still leaves its one row ("8"), and the caller
      # gets the same exception. The message is never written: it may carry
      # the signature code. If that row cannot be written either, the
      # original exception is the news, so the audit failure is logged by
      # class name and the original surfaces.
      def audit_exception(note_id, reason, agent:)
        yield
      rescue StandardError, NotImplementedError => e
        begin
          refuse_sign!(note_id, reason, agent: agent)
        rescue StandardError => audit_error
          Rails.logger.error("[audit] could not record a #{reason} note signing " \
                             "after #{e.class.name}: #{audit_error.class.name}")
        end
        raise e
      end

      def refuse_sign!(note_id, reason, agent:, raw: nil, stage: nil, note_ien: nil)
        patient = identifier(@dfn) || "none"
        record_sign_audit!(note_id, outcome: SERIOUS_REASONS.include?(reason) ? "8" : "4", agent: agent,
                           desc: "progress_note_sign_refused; patient #{patient}; reason #{reason}")
        failure(reason, raw: raw, stage: stage, note_ien: note_ien)
      end

      # Attributes are resolved on the calling thread (the agent before the
      # call, the rest here) before create_detached! may hand the write to
      # another thread. Never rescued here: a sign that cannot be audited
      # raises.
      def record_sign_audit!(note_id, outcome:, desc:, agent:)
        AuditEvent.create_detached!(
          event_type: "application",
          action: "E",
          outcome: outcome,
          outcome_desc: desc,
          **agent,
          entity_type: "DocumentReference",
          entity_identifier: note_id,
          entity_id: note_id,
          agent_network_address: AuditContext.network_address,
          tenant_identifier: AuditContext.tenant_identifier,
          facility_identifier: AuditContext.facility_identifier
        )
      end

      def failure(reason, raw: nil, stage: nil, note_ien: nil, part2_label: nil)
        Result.new(success: false, error: reason, raw: raw, stage: stage, note_ien: note_ien, part2_label: part2_label)
      end
    end
  end
end
