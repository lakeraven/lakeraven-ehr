# frozen_string_literal: true

module Lakeraven
  module EHR
    # While a tablet handover is open, every other session page redirects to
    # the kiosk before it renders. The check lives on the browser bases so a
    # page added later is covered without its own before_action.
    module ConsentKioskLock
      extend ActiveSupport::Concern

      SESSION_KEY = :consent_kiosk_lock

      included do
        # Before CSRF and every other before_action, so a locked session
        # never renders a different page, including an error page.
        prepend_before_action :redirect_when_consent_kiosk_locked
      end

      private

      def consent_kiosk_locked?
        consent_kiosk_lock["handover_token"].present?
      end

      def consent_kiosk_lock
        raw = session[SESSION_KEY]
        return {} unless raw.is_a?(Hash)

        {
          "dfn" => (raw["dfn"] || raw[:dfn]).to_s.presence,
          "template_key" => (raw["template_key"] || raw[:template_key]).to_s.presence,
          "template_version" => (raw["template_version"] || raw[:template_version]).to_i,
          "handover_token" => (raw["handover_token"] || raw[:handover_token]).to_s.presence
        }
      rescue StandardError
        {}
      end

      def store_consent_kiosk_lock!(dfn:, template_key:, template_version:, handover_token:)
        session[SESSION_KEY] = {
          "dfn" => dfn.to_s,
          "template_key" => template_key.to_s,
          "template_version" => template_version.to_i,
          "handover_token" => handover_token.to_s
        }
      end

      def clear_consent_kiosk_lock!
        session.delete(SESSION_KEY)
      end

      def redirect_when_consent_kiosk_locked
        return unless consent_kiosk_locked?
        # The patient still holds the tablet after signing. Only the kiosk
        # itself and the staff unlock may render until the lock is cleared.
        return if consent_kiosk_request?

        redirect_to consent_kiosk_path
      end

      def consent_kiosk_request?
        [ consent_kiosk_path, consent_kiosk_unlock_path ].include?(request.path.to_s)
      end
    end
  end
end
