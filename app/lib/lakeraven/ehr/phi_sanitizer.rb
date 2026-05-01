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
        # Patient names: LAST,FIRST or LAST,FIRST MIDDLE (VistA format)
        sanitized.gsub!(/\b[A-Z]{2,},[A-Z][A-Za-z]+(?:\s+[A-Z][A-Za-z]+)*(?:\s+(?:JR|SR|III?|IV|V))?\b/, "[NAME-REDACTED]")
        # DFN/HRN identifiers
        sanitized.gsub!(/\bDFN[:\s]*\d+/i, "DFN:[REDACTED]")
        sanitized.gsub!(/\bHRN[:\s]*\d+/i, "HRN:[REDACTED]")
        sanitized.gsub!(/\bpatient[_\s]*dfn[:\s]*\d+/i, "patient_dfn:[REDACTED]")
        # SSN
        sanitized.gsub!(/\b\d{3}-\d{2}-\d{4}\b/, "[SSN-REDACTED]")
        # Phone numbers: (907) 555-1234 or 907-555-1234
        sanitized.gsub!(/\(?\d{3}\)?[\s.-]?\d{3}[\s.-]?\d{4}/, "[PHONE-REDACTED]")
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
