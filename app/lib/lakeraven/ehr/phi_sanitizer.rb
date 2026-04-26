# frozen_string_literal: true

require "openssl"

module Lakeraven
  module EHR
    module PhiSanitizer
      extend self

      PHI_FIELDS = %i[
        patient_dfn dfn ssn social_security_number dob date_of_birth born_on
        tribal_enrollment_number policy_number group_number mbi medicare_id medicaid_id va_id
      ].freeze

      REDACT_FIELDS = %i[ssn social_security_number].freeze

      attr_writer :secret_key

      def hash_identifier(identifier)
        return nil if identifier.nil? || identifier.to_s.empty?
        digest = OpenSSL::HMAC.hexdigest("SHA256", resolve_secret_key, identifier.to_s)
        digest[0..11]
      end

      def sanitize_hash(data)
        return {} if data.nil?
        data.transform_keys(&:to_sym).each_with_object({}) do |(key, value), result|
          result[sanitized_key(key)] = sanitize_value(key, value)
        end
      end

      def sanitize_message(message)
        return "" if message.nil? || message.to_s.empty?
        sanitized = message.dup
        sanitized.gsub!(/\bDFN[:\s]*\d+/i, "DFN:[REDACTED]")
        sanitized.gsub!(/\bpatient[_\s]*dfn[:\s]*\d+/i, "patient_dfn:[REDACTED]")
        sanitized.gsub!(/\b\d{3}-\d{2}-\d{4}\b/, "[SSN-REDACTED]")
        sanitized
      end

      def safe_patient_context(patient_dfn)
        { patient_id_hash: hash_identifier(patient_dfn) }
      end

      private

      def resolve_secret_key
        @secret_key || rails_secret_key || "development-fallback-key"
      end

      def rails_secret_key
        return nil unless defined?(Rails) && Rails.respond_to?(:application) && Rails.application
        Rails.application.secret_key_base
      end

      def sanitized_key(key)
        case key
        when :patient_dfn, :dfn then :patient_id_hash
        when :ssn, :social_security_number then :ssn_present
        else key
        end
      end

      def sanitize_value(key, value)
        sym_key = key.to_sym
        if REDACT_FIELDS.include?(sym_key)
          value.present? ? true : false
        elsif PHI_FIELDS.include?(sym_key)
          hash_identifier(value)
        elsif value.is_a?(Hash)
          sanitize_hash(value)
        else
          value
        end
      end
    end
  end
end
