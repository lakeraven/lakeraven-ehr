# frozen_string_literal: true

module Lakeraven
  module EHR
    # The tablet handover lock. Owner: this engine.
    #
    # The browser session is a cookie. An older copy of that cookie does not
    # carry the lock, so the lock lives here, keyed by the session credential
    # every copy of the cookie shares. RPMS has no file for a tablet handover.
    class KioskLock < ApplicationRecord
      self.table_name = "lakeraven_ehr_kiosk_locks"

      # Refused signature posts for this handover. The number lives on the
      # lock row: a cookie the browser can drop must not reset the limit.
      MAX_REFUSED_SIGNATURES = 10

      validates :credential_key, :patient_dfn, :template_key, :handover_token, presence: true
      validates :credential_key, uniqueness: true
      validates :handover_token, uniqueness: true
      validates :template_version, presence: true, numericality: { only_integer: true, greater_than: 0 }

      def refused_signatures_exhausted?
        refused_signature_count.to_i >= MAX_REFUSED_SIGNATURES
      end
    end
  end
end
