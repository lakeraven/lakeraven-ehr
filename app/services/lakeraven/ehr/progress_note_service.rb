# frozen_string_literal: true

module Lakeraven
  module EHR
    # Creates a TIU progress note against an open encounter, writes its
    # text, and signs it. Signing validates the user's electronic signature
    # code before any sign action reaches the record — an invalid code
    # never touches the note.
    #
    # ESignatureGateway.validate answers what RpmsRpc::ESignature.validate
    # answers: true when RPMS accepts the code, false when it does not. Only
    # true is an accepted code. Any other answer (nil, a hash, a string) is a
    # gateway error, never an acceptance.
    #
    # The chart's flow (create_and_sign) also asks TIU which signing action
    # the author holds on the new note (ESignatureGateway.which_action) and
    # signs only when the answer is :sign.
    class ProgressNoteService
      # stage names the step a failure happened at: :signature_check (nothing
      # written), :create (no note), :text (a note may exist without its
      # text), :sign_action (the note and its text are saved, unsigned: TIU
      # does not let the author sign it), or :sign (the note and its text are
      # saved, unsigned).
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

      def sign(note_ien:, signature_code:)
        return failure(:no_note, stage: :sign) if note_ien.nil?

        checked = check_signature_code(signature_code)
        return checked unless checked.success?

        add_signature(note_ien, signature_code)
      end

      # The chart's flow: the code is checked first, so a code RPMS does not
      # accept creates no note. Then the note is created and its text
      # written. TIU is asked which signing action the author holds on it,
      # and only :sign signs it, with the code just checked. Any other answer
      # (:cosign, nil) leaves the note saved unsigned, and the code is not
      # sent.
      def create_and_sign(title_ien:, text:, signature_code:)
        checked = check_signature_code(signature_code)
        return checked unless checked.success?

        created = create(title_ien: title_ien, text: text)
        return created unless created.success?

        note_ien = created.note_ien
        action = @esignature_gateway.which_action(note_ien, @author_duz)
        return failure(:sign_not_permitted, stage: :sign_action, note_ien: note_ien) unless action == :sign

        add_signature(note_ien, signature_code)
      end

      private

      def add_signature(note_ien, signature_code)
        raw = @esignature_gateway.add(note_ien, @author_duz, signature_code, action: :sign)
        return failure(:gateway_error, raw: raw, stage: :sign, note_ien: note_ien) unless raw.is_a?(Hash) && raw[:success]

        Result.new(success: true, note_ien: note_ien, raw: raw)
      end

      def failure(reason, raw: nil, stage: nil, note_ien: nil)
        Result.new(success: false, error: reason, raw: raw, stage: stage, note_ien: note_ien)
      end
    end
  end
end
