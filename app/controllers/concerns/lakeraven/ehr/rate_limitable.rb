# frozen_string_literal: true

require "base64"
require "json"
require "openssl"

module Lakeraven
  module EHR
    # Controller declaration for #498. `rate_limit only:` registers the
    # route keys the convention test reads and refuses over-limit requests
    # before authentication or any record lookup. Calls accumulate: Rails
    # de-duplicates before_actions by name, so one callback checks the
    # per-class action set instead of installing a filter per declaration.
    #
    # `login_throttle: true` marks sessions#create, which LoginThrottle also
    # guards. The flag does not skip this limiter — that action is enforced
    # by both. Rails' own `rate_limit` takes one `by:` key and reads
    # `config.cache_store`, which this engine cannot rely on, so the counters
    # live on Lakeraven::EHR::RateLimit.
    module RateLimitable
      extend ActiveSupport::Concern

      FHIR_THROTTLE_TYPE = "application/fhir+json"
      # Prefix of the HMAC-SHA256 hex digest. Fixed length so a row never
      # stores the raw code and never stores a plain SHA256 of it.
      AUDIT_DIGEST_PREFIX = 32

      class_methods do
        def rate_limit(only:, login_throttle: false)
          register_limited_actions(only)
          install_rate_limit_enforcement!
          @login_throttle_companion = true if login_throttle
        end

        def rate_limited_actions
          @rate_limited_actions ||= []
        end

        def rate_limited_action?(action)
          rate_limited_actions.include?(action.to_s)
        end

        def register_limited_actions(only)
          RateLimit.observe_controller(self)
          Array(only).map(&:to_s).each do |action|
            RateLimit.register(controller_path, action)
            rate_limited_actions << action unless rate_limited_actions.include?(action)
          end
        end

        def install_rate_limit_enforcement!
          return if @rate_limit_enforcement_installed

          @rate_limit_enforcement_installed = true
          prepend_before_action :enforce_rate_limit!
        end
      end

      private

      def enforce_rate_limit!
        return unless self.class.rate_limited_action?(action_name)

        principal = rate_limit_principal
        ip = ClientIp.resolve(request)
        return if RateLimit.permit?(identity: principal&.dig(:key), ip: ip)

        # LoginThrottle refuses inside create, after terminate_session!.
        # This callback runs first, so a RateLimit 429 has to end the previous
        # session itself or the workstation stays signed in.
        terminate_sign_in_session!
        rate_limit_audit!(principal, ip)
        rate_limit_render!
      end

      def terminate_sign_in_session!
        return unless sign_in_request?
        return unless respond_to?(:terminate_session!, true)

        terminate_session!
      end

      def sign_in_request?
        controller_path == "lakeraven/ehr/sessions" && action_name == "create"
      end

      def rate_limit_audit!(principal, ip)
        note_audit_denial(RateLimit::AUDIT_DESCRIPTION) if respond_to?(:note_audit_denial, true)
        persist_rate_limit_audit(principal, ip) if RateLimit.audit_due?(identity: principal&.dig(:key), ip: ip)
        # The fail-closed clinical wrapper would turn a missed audit into 503.
        # A throttle still answers 429, including when the insert fails or this
        # key was already audited for the window.
        @audit_recorded = true
      end

      def persist_rate_limit_audit(principal, ip)
        ActiveRecord::Base.transaction(requires_new: true) do
          AuditEvent.create!(rate_limit_audit_attributes(principal, ip))
        end
      rescue StandardError => error
        Rails.logger.error("[rate_limit] throttle audit failed: #{error.class}")
      end

      def rate_limit_audit_attributes(principal, ip)
        {
          event_type: "security",
          action: rate_limit_audit_action,
          outcome: "4",
          outcome_desc: RateLimit::AUDIT_DESCRIPTION,
          entity_type: rate_limit_entity_type,
          agent_who_type: "Unknown",
          agent_who_identifier: rate_limit_identity_digest(principal),
          agent_network_address: ip.to_s
        }
      end

      # HMAC-SHA256 of the raw identity, keyed on the app secret and truncated
      # to a fixed prefix. A plain SHA-256 of the code or token is the same on
      # every deployment, so it is not a credential digest we can store.
      def rate_limit_identity_digest(principal)
        secret = principal&.dig(:secret)
        return if secret.blank?

        OpenSSL::HMAC.hexdigest("SHA256", rate_limit_hmac_key, secret)[0, AUDIT_DIGEST_PREFIX]
      end

      def rate_limit_hmac_key
        Rails.application.secret_key_base.to_s
      end

      def rate_limit_audit_action
        case request.request_method
        when "GET", "HEAD", "OPTIONS" then "R"
        when "POST" then "C"
        when "PUT", "PATCH" then "U"
        when "DELETE" then "D"
        else "E"
        end
      end

      def rate_limit_entity_type
        self.class.name.demodulize.delete_suffix("Controller").singularize
      end

      def rate_limit_render!
        if rate_limit_fhir_response?
          render json: rate_limit_operation_outcome, status: :too_many_requests, content_type: FHIR_THROTTLE_TYPE
        else
          render plain: "Too Many Requests", status: :too_many_requests
        end
        response.set_header("Retry-After", RateLimit.retry_after.to_s)
      end

      def rate_limit_operation_outcome
        {
          resourceType: "OperationOutcome",
          issue: [ { severity: "error", code: "throttled", diagnostics: "Too many requests" } ]
        }
      end

      def rate_limit_fhir_response?
        return true if is_a?(ApplicationController)
        return fhir_requested? if respond_to?(:fhir_requested?, true)

        false
      end

      def rate_limit_principal
        if backend_services_token?
          token_principal
        elsif sign_in_request?
          # The submitted access code, never a Bearer header. A junk
          # Authorization on POST /login must not mint a fresh bucket.
          access_code_principal
        else
          bearer_principal || session_principal
        end
      end

      def backend_services_token?
        controller_path == "lakeraven/ehr/backend_services" && action_name == "token"
      end

      # (client_id or iss, IP). Since #496 an unverified assertion cannot
      # mint tokens, a global client limb only offers a lockout DoS: any
      # address that can name the victim's client_id would spend that budget.
      # The payload is decoded only to read iss — the signature is not
      # checked, and the assertion string is never the throttle identity.
      def token_principal
        client = rate_limit_string(:client_id) || jwt_issuer(rate_limit_string(:client_assertion))
        return if client.blank?

        rate_limit_named("client", "#{client}@#{ClientIp.resolve(request)}")
      end

      def bearer_principal
        token = request.authorization.to_s[/\ABearer\s+(\S+)\z/i, 1]
        rate_limit_named("bearer", token)
      end

      def access_code_principal
        return unless controller_path == "lakeraven/ehr/sessions" && action_name == "create"

        rate_limit_named("access", rate_limit_string(:username))
      end

      def session_principal
        rate_limit_named("session", session[:duz].to_s.presence)
      rescue StandardError
        nil
      end

      def rate_limit_named(kind, value)
        return if value.blank?

        { key: "#{kind}:#{value}", secret: value.to_s }
      end

      def jwt_issuer(assertion)
        payload = jwt_payload(assertion)
        return unless payload.is_a?(Hash)

        payload["iss"].to_s.presence
      end

      def jwt_payload(assertion)
        segment = assertion.to_s.split(".", 3)[1]
        return if segment.blank?

        JSON.parse(Base64.decode64(base64_pad(segment)))
      rescue ArgumentError, JSON::ParserError
        nil
      end

      def base64_pad(segment)
        padded = segment.tr("-_", "+/")
        padded + ("=" * ((4 - (padded.length % 4)) % 4))
      end

      def rate_limit_string(name)
        value = params[name]
        value.is_a?(String) ? value.presence : nil
      end
    end
  end
end
