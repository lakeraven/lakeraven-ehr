# frozen_string_literal: true

module Lakeraven
  module EHR
    # The session SMART token, checked with the same scope rules as the chart
    # (`can_read?`) without becoming the request's `current_token`. Audit
    # attribution reads `current_token`; stashing this credential there would
    # re-file a session page under the token's application.
    class BannerToken
      include SmartAuthentication

      def self.for_session(token, duz)
        return nil unless usable_record?(token)

        candidate = new(token)
        candidate if candidate.bound_to?(duz)
      end

      def self.usable_record?(token)
        token && !token.revoked? && !token.expired?
      end

      def initialize(token)
        @current_token = token
      end

      # A browser credential bound to this session's clinician. A patient/
      # scope stores a DFN in the same column, so it cannot authorize a banner.
      def bound_to?(duz)
        return false unless browser_sso_token?(current_token)
        return false if patient_context_scope?

        current_token.resource_owner_id.to_s == duz.to_s
      end
    end
  end
end
