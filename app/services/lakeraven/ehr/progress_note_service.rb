# frozen_string_literal: true

module Lakeraven
  module EHR
    # Creates a TIU progress note against an open encounter, writes its
    # text, and signs it. Signing validates the user's electronic signature
    # code before any sign action reaches the record — an invalid code
    # never touches the note.
    class ProgressNoteService
      # stage names the step a failure happened at: :create (no note) or
      # :text (a note may exist without its text).
      Result = Struct.new(:success, :note_ien, :error, :raw, :stage, keyword_init: true) do
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
        written = @gateway.update_text(note_ien, text)
        unless written.is_a?(Hash) && written[:success]
          return failure(:gateway_error, raw: written, stage: :text, note_ien: note_ien)
        end

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

      def failure(reason, raw: nil, stage: nil, note_ien: nil)
        Result.new(success: false, error: reason, raw: raw, stage: stage, note_ien: note_ien)
      end
    end
  end
end
