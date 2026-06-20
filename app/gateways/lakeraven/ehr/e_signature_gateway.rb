# frozen_string_literal: true

require "rpms_rpc/api/e_signature"

module Lakeraven
  module EHR
    # TIU e-signature: validate a user's signature code, look up which
    # signing action is permitted on a note, add a signature (sign /
    # cosign / addend), and remove an existing signature.
    # Wraps RpmsRpc::ESignature
    class ESignatureGateway
      SIGN_FAILURE = { success: false, raw: nil }.freeze

      def self.validate(user_duz, signature_code, via: default_provider)
        return false if via.nil?

        via.validate(user_duz.to_s, signature_code)
      end

      def self.which_action(note_ien, user_duz, via: default_provider)
        return nil if via.nil?

        via.which_action(note_ien.to_s, user_duz.to_s)
      end

      def self.add(note_ien, user_duz, signature_code, action: :sign, via: default_provider)
        return SIGN_FAILURE if via.nil?

        via.add(note_ien.to_s, user_duz.to_s, signature_code, action: action)
      end

      def self.remove(note_ien, user_duz, reason:, via: default_provider)
        return SIGN_FAILURE if via.nil?

        via.remove(note_ien.to_s, user_duz.to_s, reason: reason)
      end

      def self.default_provider
        ::RpmsRpc::ESignature
      end
    end
  end
end
