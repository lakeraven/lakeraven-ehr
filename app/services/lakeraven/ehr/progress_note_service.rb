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
    # every path, and fails closed: if the row cannot be written, the
    # exception propagates. On success the row holds a SHA-256 of the note
    # text that was signed; the signature code and the text never reach it.
    class ProgressNoteService
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
        return refuse_sign!(note_ien, :no_note) if note_ien.nil?

        validation = @esignature_gateway.validate(@author_duz, signature_code)
        return refuse_sign!(note_ien, :gateway_error, raw: validation) unless validation.is_a?(Hash)
        return refuse_sign!(note_ien, :invalid_signature_code, raw: validation) unless validation[:success]

        # We never sign what we cannot hash.
        text = @gateway.fetch_text(note_ien)
        return refuse_sign!(note_ien, :note_text_unavailable) unless text.is_a?(String)

        raw = @esignature_gateway.add(note_ien, @author_duz, signature_code, action: :sign)
        return refuse_sign!(note_ien, :gateway_error, raw: raw) unless raw.is_a?(Hash) && raw[:success]

        record_sign_audit!(note_ien, outcome: "0",
                           desc: "progress_note_signed; patient #{@dfn}; content-sha256 #{Digest::SHA256.hexdigest(text)}")
        Result.new(success: true, note_ien: note_ien, raw: raw)
      end

      private

      # Gateway errors are serious failures ("8"); every other refusal is
      # a minor failure ("4").
      def refuse_sign!(note_ien, reason, raw: nil)
        record_sign_audit!(note_ien, outcome: reason == :gateway_error ? "8" : "4",
                           desc: "progress_note_sign_refused; patient #{@dfn}; reason #{reason}")
        failure(reason, raw: raw)
      end

      # Attributes are resolved here, on the calling thread, before
      # create_detached! may hand the write to another thread. Never rescued:
      # a sign that cannot be audited raises.
      def record_sign_audit!(note_ien, outcome:, desc:)
        note_id = note_ien&.to_s
        AuditEvent.create_detached!(
          event_type: "application",
          action: "E",
          outcome: outcome,
          outcome_desc: desc,
          agent_who_type: "Practitioner",
          agent_who_identifier: @author_duz.to_s,
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
