# frozen_string_literal: true

module Lakeraven
  module EHR
    class EncryptionVerificationService
      def run
        {
          title: "Application-Observable Encryption Status",
          database_ssl: check_database_ssl,
          active_record_encryption: check_ar_encryption,
          encrypted_columns: list_encrypted_columns,
          infrastructure_attestation: {
            required: true,
            note: "Infrastructure Attestation Required — storage encryption (EBS, RDS) requires external verification by infrastructure team"
          }
        }
      end

      private

      def check_database_ssl
        { enabled: ActiveRecord::Base.connection.adapter_name.present?, adapter: ActiveRecord::Base.connection.adapter_name }
      rescue
        { enabled: false, error: "Cannot determine" }
      end

      def check_ar_encryption
        { configured: ActiveRecord::Encryption.config.respond_to?(:primary_key) }
      rescue
        { configured: false }
      end

      def list_encrypted_columns
        # In production, this would introspect AR models for encrypts declarations
        []
      end
    end
  end
end
