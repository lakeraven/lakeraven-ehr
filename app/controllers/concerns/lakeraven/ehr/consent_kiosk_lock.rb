# frozen_string_literal: true

module Lakeraven
  module EHR
    # While a tablet handover is open, every other session page redirects to
    # the kiosk before it renders. The check lives on the browser bases so a
    # page added later is covered without its own before_action.
    #
    # The cookie is only a hint. The lock row is keyed by the Doorkeeper
    # access token id behind session[:smart_token], which every copy of that
    # session cookie shares. Include this concern BEFORE AuditableClinicalAccess
    # so the audit wrapper is prepended afterwards and stays outside this
    # redirect; a denial noted here is then recorded, with the staff DUZ.
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
        record = active_kiosk_lock
        return {} unless record

        lock_payload(record)
      end

      def lock_payload(record)
        {
          "dfn" => record.patient_dfn.to_s.presence,
          "template_key" => record.template_key.to_s.presence,
          "template_version" => record.template_version.to_i,
          "handover_token" => record.handover_token.to_s.presence
        }
      end

      def active_kiosk_lock
        return @active_kiosk_lock if defined?(@active_kiosk_lock)

        @active_kiosk_lock = load_active_kiosk_lock
      end

      def load_active_kiosk_lock
        key = kiosk_lock_credential_key
        return nil if key.blank? || @kiosk_lock_unreadable

        KioskLock.find_by(credential_key: key)
      rescue StandardError => error
        Rails.logger.error("[consent-kiosk] lock could not be read: #{error.class}")
        @kiosk_lock_unreadable = true
        nil
      end

      def kiosk_lock_unreadable?
        active_kiosk_lock
        @kiosk_lock_unreadable == true
      end

      def store_consent_kiosk_lock!(dfn:, template_key:, template_version:, handover_token:)
        key = kiosk_lock_credential_key
        return false if key.blank?
        return false unless save_kiosk_lock!(key, dfn, template_key, template_version, handover_token)

        remember_kiosk_lock_hint!(dfn, template_key, template_version, handover_token)
        true
      rescue ActiveRecord::ActiveRecordError => error
        Rails.logger.error("[consent-kiosk] lock was not stored: #{error.class}")
        false
      end

      # Insert only. Updating a row that is already there would point the
      # tablet at a different handover. The savepoint keeps a unique-index
      # collision from aborting the audit transaction, so the loser can
      # still record why it was refused.
      def save_kiosk_lock!(key, dfn, template_key, template_version, handover_token)
        return false unless insert_kiosk_lock!(key, dfn, template_key, template_version, handover_token)

        reset_kiosk_lock_memo!
        true
      end

      def insert_kiosk_lock!(key, dfn, template_key, template_version, handover_token)
        KioskLock.transaction(requires_new: true) do
          create_kiosk_lock_row!(key, dfn, template_key, template_version, handover_token)
        end
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => error
        Rails.logger.error("[consent-kiosk] lock was not stored: #{error.class}")
        false
      end

      def create_kiosk_lock_row!(key, dfn, template_key, template_version, handover_token)
        held = KioskLock.find_or_initialize_by(credential_key: key)
        if held.persisted?
          Rails.logger.error("[consent-kiosk] lock was not stored: a lock row already exists")
          return false
        end

        KioskLock.create!(kiosk_lock_row(key, dfn, template_key, template_version, handover_token))
        true
      end

      def kiosk_lock_row(key, dfn, template_key, template_version, handover_token)
        kiosk_lock_attributes(dfn, template_key, template_version, handover_token).merge(credential_key: key)
      end

      def kiosk_lock_attributes(dfn, template_key, template_version, handover_token)
        {
          patient_dfn: dfn.to_s, template_key: template_key.to_s,
          template_version: template_version.to_i, handover_token: handover_token.to_s
        }
      end

      def remember_kiosk_lock_hint!(dfn, template_key, template_version, handover_token)
        session[SESSION_KEY] = {
          "dfn" => dfn.to_s, "template_key" => template_key.to_s,
          "template_version" => template_version.to_i, "handover_token" => handover_token.to_s
        }
      end

      def clear_consent_kiosk_lock!
        released = release_consent_kiosk_lock!
        session.delete(SESSION_KEY)
        released
      end

      # True when there was nothing to release, or the row is gone. False when
      # the delete failed: the caller stays locked and says why.
      def release_consent_kiosk_lock!
        key = kiosk_lock_credential_key
        return true if key.blank?

        KioskLock.where(credential_key: key).delete_all
        reset_kiosk_lock_memo!
        true
      rescue StandardError => error
        Rails.logger.error("[consent-kiosk] lock could not be released: #{error.class}")
        false
      end

      def reset_kiosk_lock_memo!
        remove_instance_variable(:@active_kiosk_lock) if defined?(@active_kiosk_lock)
      end

      def kiosk_lock_credential_key
        token = session_access_token
        return nil if token.nil? || @kiosk_lock_unreadable

        "doorkeeper-access-token-#{token.id}"
      end

      def session_access_token
        return @session_access_token if defined?(@session_access_token)

        @session_access_token = load_session_access_token
      end

      def load_session_access_token
        raw = session_token_raw
        return nil if raw.blank?

        Doorkeeper::AccessToken.by_token(raw)
      rescue StandardError => error
        Rails.logger.error("[consent-kiosk] session credential could not be read: #{error.class}")
        @kiosk_lock_unreadable = true
        nil
      end

      def session_token_raw
        session[:smart_token].presence
      rescue StandardError
        nil
      end

      def redirect_when_consent_kiosk_locked
        return refuse_unreadable_kiosk_lock if kiosk_lock_unreadable?
        return unless consent_kiosk_locked?
        return if consent_kiosk_request?

        response.headers["Cache-Control"] = "no-store"
        note_lock_denial!
        redirect_to consent_kiosk_path
      end

      def refuse_unreadable_kiosk_lock
        response.headers["Cache-Control"] = "no-store"
        note_audit_denial("consent kiosk lock could not be read; page refused") if respond_to?(:note_audit_denial, true)
        render plain: "The consent lock could not be read, so this page was refused.", status: :service_unavailable
      end

      def note_lock_denial!
        bind_session_token_for_audit!
        return unless respond_to?(:note_audit_denial, true)

        note_audit_denial("consent kiosk lock refused this page")
      end

      # ChartsController is not a session-authenticated surface, so the audit
      # names a human only from the browser token. WebController already has
      # session[:duz]; binding a token there would hide that DUZ on a mismatch.
      def bind_session_token_for_audit!
        return if respond_to?(:session_authenticated_surface?, true) && session_authenticated_surface?
        return unless respond_to?(:current_token, true) && current_token.nil?

        token = session_access_token
        return unless token && respond_to?(:browser_sso_token?, true) && browser_sso_token?(token)

        @current_token = token
      end

      def consent_kiosk_request?
        [ consent_kiosk_path, consent_kiosk_unlock_path ].include?(request.path.to_s)
      end
    end
  end
end
