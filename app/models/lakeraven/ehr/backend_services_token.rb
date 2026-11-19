# frozen_string_literal: true

module Lakeraven
  module EHR
    # Whether an access token is a SMART Backend Services token: a client
    # application's own, with no person behind it. Not launched, not a browser
    # session's, no resource owner, and every scope it carries is system/.
    # Anything else (a user/ or patient/ scope, openid, launch/...,
    # offline_access) is not one. Only such a token rides its application's
    # service account (ApplicationController), and only its revocation ends
    # that session (ServiceAccountLeaseRelease).
    module BackendServicesToken
      # launched: whether the token was issued from a SMART App Launch
      # authorization; looked up when the caller has not already.
      def self.match?(token, launched: nil)
        return false if token.nil? || token.resource_owner_id.present?

        launched = SmartAuthorization.for_access_token(token).present? if launched.nil?
        return false if launched || SmartAuthentication.browser_sso_token?(token)

        raw = token.scopes.to_a.map(&:to_s)
        return false unless raw.all? { |scope| scope.start_with?("system/") }

        scopes = SmartScope.parse_all(raw)
        scopes.any? && scopes.all? { |scope| scope.context == "system" }
      end
    end
  end
end
