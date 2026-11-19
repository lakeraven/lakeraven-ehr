# frozen_string_literal: true

module Lakeraven
  module EHR
    # Revoking a Backend Services token ends its application's service-account
    # session (ADR 0011 §4, §6): RPMS logs off the connection, signed on as the
    # application's own service account, that every Backend Services token of
    # the application shares. Revoking any other token of the same application
    # (one with a resource owner, a launched one, a browser session's: none of
    # them rides the lease, BackendServicesToken) leaves it alone, and a token
    # whose application holds no lease releases nothing. Browser and launch
    # sessions are keyed differently (RpmsSessions.key_for) and released where
    # they end.
    module ServiceAccountLeaseRelease
      extend ActiveSupport::Concern

      included do
        after_commit :release_service_account_lease,
                     if: -> { saved_change_to_revoked_at? && revoked_at.present? && RpmsSessions.enabled? }
      end

      private

      def release_service_account_lease
        RpmsSessions.release_service_account(self) if BackendServicesToken.match?(self)
      end
    end
  end
end
