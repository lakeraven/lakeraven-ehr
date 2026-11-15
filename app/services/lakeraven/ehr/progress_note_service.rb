# frozen_string_literal: true

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
    # does not stop the note (part2_label is :label_failed); read-time
    # Part2Posture still treats an unlabelled suspected note as Part 2.
    class ProgressNoteService
      PART2_RECORD_TYPE = Part2Label::TIU_NOTE

      Result = Struct.new(:success, :note_ien, :error, :raw, :part2_label, keyword_init: true) do
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
        part2_label = label_part2(note_ien, text)

        written = @gateway.update_text(note_ien, text)
        unless written.is_a?(Hash) && written[:success]
          return failure(:gateway_error, raw: written, part2_label: part2_label)
        end

        Result.new(success: true, note_ien: note_ien, raw: written, part2_label: part2_label)
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

      # Labels before the text is written, so the label never trails the
      # content. classify never raises (blank or unreadable text is
      # :unclassified and labelled). A note the gateway gave no IEN cannot be
      # labelled, so it is never reported as :labelled. Only database errors
      # are rescued: the note must not be blocked by a label write, and
      # Part2Posture fails closed for it.
      def label_part2(note_ien, text)
        return :not_suspected if SudContentSuspicion.classify(text) == :not_suspected
        return :label_failed if note_ien.to_s.strip.empty?

        Part2Label.mark!(patient_dfn: @dfn.to_s, record_type: PART2_RECORD_TYPE, record_id: note_ien.to_s)
        :labelled
      rescue ActiveRecord::ActiveRecordError
        :label_failed
      end

      def failure(reason, raw: nil, part2_label: nil)
        Result.new(success: false, error: reason, raw: raw, part2_label: part2_label)
      end
    end
  end
end
