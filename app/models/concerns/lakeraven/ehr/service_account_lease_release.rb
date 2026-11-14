# frozen_string_literal: true

module Lakeraven
  module EHR
    # Revoking an access token ends its application's service-account session
    # (ADR 0011 §4, §6): RPMS logs off the service account's connection that
    # every token of the application shares. A token with no such lease
    # releases nothing. Browser and launch sessions
    # are keyed differently (RpmsSessions.key_for) and released where they end.
    module ServiceAccountLeaseRelease
      extend ActiveSupport::Concern

      included do
        after_commit :release_service_account_lease,
                     if: -> { saved_change_to_revoked_at? && revoked_at.present? && RpmsSessions.enabled? }
      end

      private

      def release_service_account_lease = RpmsSessions.release_service_account(self)
    end
  end
end
