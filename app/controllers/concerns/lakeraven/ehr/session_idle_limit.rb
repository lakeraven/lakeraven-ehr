# frozen_string_literal: true

module Lakeraven
  module EHR
    # Idle limit shared by the browser session and the SMART session check,
    # so the two cannot drift. The site's session_idle_limit, or the user's
    # RPMS DTIME (session[:rpms_idle_seconds], read at sign-on) when that is
    # shorter. RPMS may make the limit stricter, never looser.
    module SessionIdleLimit
      extend ActiveSupport::Concern

      private

      def session_idle_expired?
        last_seen = session[:last_seen_at]
        return false if last_seen.blank?

        Time.current.to_i - last_seen.to_i > session_idle_limit
      end

      def session_idle_limit
        site = Lakeraven::EHR.configuration.session_idle_limit.to_i
        [ session[:rpms_idle_seconds].presence&.to_i, site ].compact.min
      end
    end
  end
end
