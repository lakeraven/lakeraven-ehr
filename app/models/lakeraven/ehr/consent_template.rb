# frozen_string_literal: true

module Lakeraven
  module EHR
    # Versioned wording for an in-clinic consent. Owner: this engine.
    #
    # RPMS cannot hold it. The signed row freezes the exact body the patient
    # saw, and RPMS has no template file that stays immutable once published.
    # The three installed texts are synthetic placeholders, not a facility's forms.
    class ConsentTemplate < ApplicationRecord
      self.table_name = "lakeraven_ehr_consent_templates"

      KEYS = %w[bh-treatment telehealth release-of-information].freeze

      # Placeholder wording only. No person, facility, or tribe.
      DEFAULTS = [
        {
          key: "bh-treatment",
          title: "SYNTHETIC BH treatment consent",
          consent_scope: "treatment",
          body: "SYNTHETIC placeholder text for a behavioral health treatment consent. " \
                "It describes treatment only and names no person, facility, or tribe."
        },
        {
          key: "telehealth",
          title: "SYNTHETIC telehealth consent",
          consent_scope: "treatment",
          body: "SYNTHETIC placeholder text for a telehealth consent. " \
                "It describes remote treatment only and names no person, facility, or tribe."
        },
        {
          key: "release-of-information",
          title: "SYNTHETIC release of information consent",
          consent_scope: "hipaa-auth",
          body: "SYNTHETIC placeholder text for a release of information consent. " \
                "It describes a records authorization only and names no person, facility, or tribe."
        }
      ].freeze

      include ImmutablePersistedRow

      validates :key, presence: true
      validates :version, presence: true, uniqueness: { scope: :key }
      validates :title, :body, presence: true
      validates :consent_scope, presence: true, inclusion: { in: Consent::SCOPES.keys }

      def self.install_defaults!
        DEFAULTS.each do |attrs|
          find_or_create_by!(key: attrs[:key], version: 1) do |row|
            row.title = attrs[:title]
            row.body = attrs[:body]
            row.consent_scope = attrs[:consent_scope]
          end
        end
      end

      def self.current(key)
        where(key: key).order(version: :desc).first
      end

      # A published template is the body a signature may already have digested.
      def readonly?
        persisted?
      end
    end
  end
end
