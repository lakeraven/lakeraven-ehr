# frozen_string_literal: true

require "digest"

module Lakeraven
  module EHR
    # Creates a TIU progress note against an open encounter, writes its
    # text, and signs it. Signing validates the user's electronic signature
    # code before any sign action reaches the record — an invalid code
    # never touches the note.
    #
    # Every sign call writes exactly one append-only AuditEvent (#960), on
    # every path, including a gateway that raises (the row is written, then
    # the same exception is re-raised). The signature code, the note text
    # and exception messages never reach the row.
    #
    # On success the row holds a SHA-256 of the note BODY rows, as
    # ProgressNoteGateway.fetch_body returns them, joined with "\n", and the
    # row count. The TIU header and the signature block TIU appends on
    # signing are not covered: a verifier re-reads the body and hashes its
    # first content-rows rows.
    #
    # It fails closed: a row that cannot be written raises. The residual: if
    # the success row fails after the sign action, the RPMS signature stands
    # and the exception surfaces to the caller.
    class ProgressNoteService
      # Serious failures ("8"): gateway errors, raised gateway calls and a
      # sign whose outcome is unknown. Every other refusal is minor ("4").
      SERIOUS_REASONS = %i[gateway_error gateway_exception sign_outcome_unknown].freeze

      Result = Struct.new(:success, :note_ien, :error, :raw, keyword_init: true) do
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
      end

      def create(title_ien:, text:)
        return failure(:invalid_input) if @dfn.nil? || @visit_ien.nil?
        return failure(:missing_title) if title_ien.nil?

        created = @gateway.create(@dfn, @visit_ien, title_ien)
        return failure(:gateway_error, raw: created) unless created.is_a?(Hash) && created[:success]

        note_ien = created[:ien]
        written = @gateway.update_text(note_ien, text)
        return failure(:gateway_error, raw: written) unless written.is_a?(Hash) && written[:success]

        Result.new(success: true, note_ien: note_ien, raw: written)
      end

      def sign(note_ien:, signature_code:)
        agent = sign_agent
        note_id = identifier(note_ien)
        return refuse_sign!(note_id, :invalid_input, agent: agent) if identifier(@dfn).nil?
        return refuse_sign!(nil, :no_note, agent: agent) if note_ien.nil?
        return refuse_sign!(nil, :invalid_input, agent: agent) if note_id.nil?
        return refuse_sign!(note_id, :actor_mismatch, agent: agent) unless author_agent?(agent)

        validation = audit_exception(note_id, :gateway_exception, agent: agent) do
          @esignature_gateway.validate(@author_duz, signature_code)
        end
        valid = signature_valid?(validation)
        return refuse_sign!(note_id, :gateway_error, agent: agent, raw: validation) if valid.nil?
        return refuse_sign!(note_id, :invalid_signature_code, agent: agent, raw: validation) unless valid

        # We never sign what we cannot hash, and an empty body never verifies.
        rows = audit_exception(note_id, :gateway_exception, agent: agent) { @gateway.fetch_body(note_ien) }
        return refuse_sign!(note_id, :note_text_unavailable, agent: agent) unless body_rows?(rows)

        # The RPC may have filed before it raised, so the row does not claim
        # the note is unsigned.
        raw = audit_exception(note_id, :sign_outcome_unknown, agent: agent) do
          @esignature_gateway.add(note_ien, @author_duz, signature_code, action: :sign)
        end
        return refuse_sign!(note_id, :gateway_error, agent: agent, raw: raw) unless raw.is_a?(Hash) && raw[:success]

        record_sign_audit!(note_id, outcome: "0", agent: agent,
                           desc: "progress_note_signed; patient #{@dfn}; " \
                                 "content-sha256 #{Digest::SHA256.hexdigest(rows.join("\n"))}; " \
                                 "content-rows #{rows.size}")
        Result.new(success: true, note_ien: note_ien, raw: raw)
      end

      private

      # The value as a String when it is all digits, else nil, so a
      # malformed identifier never reaches the row.
      def identifier(value)
        id = value.to_s
        id.match?(AuditEvent::PATIENT_IDENTIFIER_PATTERN) ? id : nil
      end

      # The attributed identity when AuditContext has one, else the author.
      def sign_agent
        attributed = AuditContext.agent_attributes
        return attributed unless attributed[:agent_who_identifier].nil?

        { agent_who_type: "Practitioner", agent_who_identifier: @author_duz.to_s }
      end

      def author_agent?(agent)
        agent[:agent_who_type] == "Practitioner" && agent[:agent_who_identifier].to_s == @author_duz.to_s
      end

      # Production ESignatureGateway.validate returns a Boolean; the demo
      # and test fakes return a Hash. True or false, or nil for a reply of
      # any other shape.
      def signature_valid?(validation)
        case validation
        when true, false then validation
        when Hash then validation[:success] ? true : false
        end
      end

      def body_rows?(rows)
        rows.is_a?(Array) && rows.all?(String) && rows.any?(&:present?)
      end

      # A gateway that raises still leaves its one row ("8"), and the caller
      # gets the same exception. The message is never written: it may carry
      # the signature code. If that row cannot be written either, the
      # original exception is the news, so the audit failure is logged by
      # class name and the original surfaces.
      def audit_exception(note_id, reason, agent:)
        yield
      rescue StandardError => e
        begin
          refuse_sign!(note_id, reason, agent: agent)
        rescue StandardError => audit_error
          Rails.logger.error("[audit] could not record a #{reason} note signing " \
                             "after #{e.class.name}: #{audit_error.class.name}")
        end
        raise e
      end

      def refuse_sign!(note_id, reason, agent:, raw: nil)
        patient = identifier(@dfn) || "none"
        record_sign_audit!(note_id, outcome: SERIOUS_REASONS.include?(reason) ? "8" : "4", agent: agent,
                           desc: "progress_note_sign_refused; patient #{patient}; reason #{reason}")
        failure(reason, raw: raw)
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

      def failure(reason, raw: nil)
        Result.new(success: false, error: reason, raw: raw)
      end
    end
  end
end
