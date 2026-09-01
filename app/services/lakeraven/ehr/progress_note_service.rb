# frozen_string_literal: true

module Lakeraven
  module EHR
    # Creates a TIU progress note against an open encounter, writes its
    # text, and signs it. Signing validates the user's electronic signature
    # code before any sign action reaches the record — an invalid code
    # never touches the note.
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
        return failure(:no_note) if note_ien.nil?

        validation = @esignature_gateway.validate(@author_duz, signature_code)
        return failure(:gateway_error, raw: validation) unless validation.is_a?(Hash)
        return failure(:invalid_signature_code, raw: validation) unless validation[:success]

        raw = @esignature_gateway.add(note_ien, @author_duz, signature_code, action: :sign)
        return failure(:gateway_error, raw: raw) unless raw.is_a?(Hash) && raw[:success]

        Result.new(success: true, note_ien: note_ien, raw: raw)
      end

      private

      def failure(reason, raw: nil)
        Result.new(success: false, error: reason, raw: raw)
      end
    end
  end
end
