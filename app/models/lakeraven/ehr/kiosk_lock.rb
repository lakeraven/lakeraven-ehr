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

      validates :credential_key, :patient_dfn, :template_key, :handover_token, presence: true
      validates :credential_key, uniqueness: true
      validates :handover_token, uniqueness: true
      validates :template_version, presence: true, numericality: { only_integer: true, greater_than: 0 }
    end
  end
end
