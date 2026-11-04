# frozen_string_literal: true

require "digest"

module Lakeraven
  module EHR
    # One in-clinic signature, or a later revocation of one. Owner: this engine.
    #
    # RPMS cannot hold it. The row is the evidence of a tablet handover: the
    # PNG the patient drew, the digest of the exact body they were shown, and
    # the witness DUZ. A revocation is a new row. The signature is never updated.
    class SignedConsent < ApplicationRecord
      self.table_name = "lakeraven_ehr_signed_consents"

      class NotRevocable < StandardError; end

      KIND_SIGNATURE = "signature"
      KIND_REVOCATION = "revocation"
      KINDS = [ KIND_SIGNATURE, KIND_REVOCATION ].freeze
      PNG_MAGIC = SignaturePng::MAGIC
      MAX_SIGNATURE_BYTES = 500.kilobytes
      DATA_URL = %r{\Adata:image/png;base64,([A-Za-z0-9+/]+=*)\z}

      include ImmutablePersistedRow

      # The PNG decode from this request, so validation does not inflate again.
      attr_accessor :decoded_signature

      belongs_to :consent_template, class_name: "Lakeraven::EHR::ConsentTemplate"
      validate :revocation_names_a_consent, if: -> { kind == KIND_REVOCATION }

      validates :patient_dfn, :template_key, :template_body_digest, :signed_at, :recorded_by_duz, presence: true
      validates :template_version, presence: true, numericality: { only_integer: true }
      validates :kind, inclusion: { in: KINDS }
      validates :handover_token, uniqueness: true, allow_nil: true
      validate :snapshot_matches_template
      validate :row_shape
      validate :text_fields_are_utf8

      scope :signatures, -> { where(kind: KIND_SIGNATURE) }

      def self.signatures_for_patient(dfn)
        signatures.where(patient_dfn: dfn.to_s).order(:id)
      end

      def self.digest_for(body)
        Digest::SHA256.hexdigest(body.to_s)
      end

      # Signer name and revocation reason are stored as text. Nil is allowed.
      # Anything else must already be a UTF-8 String with no NUL. A non-string
      # is refused: Array#to_s and Hash#to_s are inspect text, which escapes a
      # NUL and would pass a check of the coerced value.
      def self.acceptable_text?(value)
        return true if value.nil?
        return false unless value.is_a?(String)
        return false unless value.encoding == Encoding::UTF_8 && value.valid_encoding?

        !value.include?("\0")
      end

      # The canvas posts a PNG data URL. Stored bytes are the PNG itself.
      # Blank, non-PNG, undecodable, inkless, and oversize payloads are refused
      # before a row exists. The returned parser is the one validation reuses,
      # so a request inflates the bitmap once.
      def self.decode_signature_data_url(value)
        bytes = decode_data_url_bytes(value)
        return nil unless bytes

        parsed = SignaturePng.new(bytes)
        return nil unless parsed.acceptable?

        parsed
      end

      def self.decode_data_url_bytes(value)
        text = value.to_s
        return nil if text.blank?
        return nil if text.bytesize > (MAX_SIGNATURE_BYTES * 4 / 3) + 64

        encoded = DATA_URL.match(text)&.[](1)
        return nil if encoded.blank? || (encoded.length % 4).nonzero?

        bytes = Base64.strict_decode64(encoded).b
        return nil if bytes.bytesize > MAX_SIGNATURE_BYTES

        bytes
      rescue ArgumentError
        nil
      end
      private_class_method :decode_data_url_bytes

      def self.record_signature!(attributes)
        decoded = attributes.delete(:decoded_signature)
        token = attributes[:handover_token].presence
        found = existing_for_handover(token)
        return found.mark_already_stored! if found

        without_statement_log { insert_signature!(attributes, decoded) }
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
        recovered = existing_for_handover(token)
        raise if recovered.nil?

        recovered.mark_already_stored!
      end

      def self.existing_for_handover(token)
        return nil if token.blank?

        find_by(handover_token: token)
      end
      private_class_method :existing_for_handover

      # The unique handover index is the race. A savepoint keeps that violation
      # from aborting the audit transaction around the request.
      def self.insert_signature!(attributes, decoded = nil)
        transaction(requires_new: true) do
          row = new(attributes)
          row.decoded_signature = decoded
          row.save!
          row
        end
      end
      private_class_method :insert_signature!

      # Statement text would contain the PNG and the typed name.
      def self.without_statement_log
        loggers = [ Rails.logger, ActiveRecord::Base.logger ].compact.uniq
        loggers = loggers.select { |logger| logger.respond_to?(:silence) }
        runner = proc { yield }
        loggers.reverse_each do |logger|
          inner = runner
          runner = proc { logger.silence(&inner) }
        end
        runner.call
      end

      # A racing second post of this handover found the row already stored.
      # The kiosk audits that as a read, not as another consent create.
      def already_stored?
        @already_stored == true
      end

      def mark_already_stored!
        @already_stored = true
        self
      end

      def readonly?
        persisted?
      end

      def signature_png
        self[:signature_png]&.b
      end

      def revoke!(by_duz:, reason:)
        raise NotRevocable, "only a signature can be revoked" unless kind == KIND_SIGNATURE
        raise NotRevocable, "already revoked" if revocation_recorded?

        insert_revocation!(by_duz, reason)
      rescue ActiveRecord::RecordNotUnique
        raise NotRevocable, "already revoked"
      end

      def to_consent
        Consent.new(
          id: id&.to_s,
          patient_dfn: patient_dfn,
          scope: consent_template.consent_scope,
          status: revoked? ? "revoked" : "active",
          provision_type: "permit",
          performer_ien: witness_duz,
          date_time: signed_at.to_date
        )
      end

      def revoked?
        return false unless persisted? && kind == KIND_SIGNATURE

        self.class.exists?(kind: KIND_REVOCATION, revokes_id: id)
      end

      private

      def revocation_recorded?
        self.class.exists?(kind: KIND_REVOCATION, revokes_id: id)
      end

      # Same savepoint as a signature insert: the loser of a double revoke
      # must still be able to write its audit row.
      def insert_revocation!(by_duz, reason)
        attrs = revocation_attributes(by_duz, reason)
        self.class.without_statement_log do
          self.class.transaction(requires_new: true) { self.class.create!(attrs) }
        end
      end

      def revocation_attributes(by_duz, reason)
        {
          patient_dfn: patient_dfn, consent_template: consent_template,
          template_key: template_key, template_version: template_version,
          template_body_digest: template_body_digest, signed_at: Time.current,
          witness_duz: by_duz.to_s, kind: KIND_REVOCATION, recorded_by_duz: by_duz.to_s,
          revokes_id: id, revocation_reason: reason
        }
      end

      # The column casts with to_s before the attribute reader. Validation has
      # to see the assigned value, or an array's inspect text hides a NUL.
      def text_fields_are_utf8
        errors.add(:signer_name, "must be valid text") unless self.class.acceptable_text?(given_text(:signer_name))
        errors.add(:revocation_reason, "must be valid text") unless self.class.acceptable_text?(given_text(:revocation_reason))
      end

      def given_text(attribute)
        public_send(:"#{attribute}_before_type_cast")
      end

      def snapshot_matches_template
        return if consent_template.nil?

        if template_key != consent_template.key
          errors.add(:template_key, "does not match the template")
        end
        if template_version != consent_template.version
          errors.add(:template_version, "does not match the template")
        end
        return if template_body_digest.blank?

        expected = self.class.digest_for(consent_template.body)
        return if template_body_digest == expected

        errors.add(:template_body_digest, "does not match the template body")
      end

      def row_shape
        if kind == KIND_REVOCATION
          errors.add(:revokes_id, "must name the consent being revoked") if revokes_id.blank?
          errors.add(:revocation_reason, "must be present") if revocation_reason.blank?
          errors.add(:signature_png, "must be empty on a revocation") if self[:signature_png].present?
          return
        end

        errors.add(:witness_duz, "must be present") if witness_duz.blank?
        errors.add(:revokes_id, "must be empty on a signature") if revokes_id.present?
        errors.add(:revocation_reason, "must be empty on a signature") if revocation_reason.present?
        validate_signature_png
      end

      def validate_signature_png
        bytes = signature_png
        if bytes.blank?
          errors.add(:signature_png, "must be a PNG")
          return
        end
        if bytes.bytesize > MAX_SIGNATURE_BYTES
          errors.add(:signature_png, "is larger than 500 KB")
          return
        end
        return if acceptable_signature_png?(bytes)

        errors.add(:signature_png, "must be a PNG with ink")
      end

      def acceptable_signature_png?(bytes)
        parsed = decoded_signature
        parsed = nil unless parsed.respond_to?(:same_bytes?) && parsed.same_bytes?(bytes)
        parsed ||= SignaturePng.new(bytes)
        self.decoded_signature = parsed
        parsed.acceptable?
      end

      # `exists?` is not used: a revocation race stubs that query. `pick` still
      # sees whether the named row was stored. The foreign key is the backstop.
      def revocation_names_a_consent
        return if revokes_id.blank?
        return if self.class.where(id: revokes_id).pick(:id)

        errors.add(:revokes_id, "must reference an existing consent")
      end
    end
  end
end
