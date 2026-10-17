# frozen_string_literal: true

module Lakeraven
  module EHR
    # Layout pages share one banner. The active patient is the session
    # context (ClinicianPatientContext::SESSION_KEY) — not a new key, and
    # not whatever :dfn the route happens to carry.
    #
    # Reading it is a patient-data access. `audit_settled?` is false until
    # the row is written, which is after the render, so the banner cannot
    # gate on that predicate — every signed-in page would go blank. What
    # `audit_settled?` treats as settled WITHOUT a row is `!auditable_access?`.
    # That request must not carry clinical data. If the row is then refused,
    # the wrapper discards this response.
    module PatientBannerRendering
      extend ActiveSupport::Concern

      include FHIRReadEgress

      # Path keys that name a record. Query-string copies of these are not
      # the route: `request.path_parameters` is, `params` is not.
      ROUTE_RECORD_KEYS = %i[dfn id ien _id].freeze

      included do
        helper_method :patient_banner
      end

      def patient_banner
        return @patient_banner if defined?(@patient_banner_built)

        @patient_banner_built = true
        @patient_banner = build_patient_banner
      end

      private

      def build_patient_banner
        return unless signed_in_banner_page?

        dfn = open_banner_dfn
        return PatientBanner.empty if dfn.blank?
        # The layout wraps the open-record page too. A route dfn that is not
        # the session patient must not read that session patient's chart —
        # screenings index/new/show/create all render through here.
        return PatientBanner.unopened_route(route_param(:dfn)) if route_patient_disagrees?(dfn)

        remember_banner_patient!(dfn) unless route_names_record?
        return PatientBanner.closed unless banner_read_allowed?

        load_patient_banner(dfn)
      rescue StandardError => e
        Rails.logger.warn("[patient-banner] banner read failed: #{e.class}")
        PatientBanner.closed
      end

      # The sign-in form renders this layout too. A banner there, even the
      # empty state, is patient-context chrome on a page that has none.
      def signed_in_banner_page?
        !is_a?(SessionsController) && session[:duz].present?
      end

      def open_banner_dfn
        session[ClinicianPatientContext::SESSION_KEY].presence
      end

      def banner_read_allowed?
        auditable_access? && banner_token && banner_scope_allows_read?
      end

      def banner_scope_allows_read?
        banner_token.can_read?("Patient") || banner_token.can_read?("AllergyIntolerance")
      end

      def remember_banner_patient!(dfn)
        @patient_banner_audit_dfn = dfn
      end

      def load_patient_banner(dfn)
        PatientBannerLoader.new(
          dfn: dfn,
          can_read: banner_token.method(:can_read?),
          filter: method(:filter_fhir_for_egress)
        ).load
      end

      def banner_token
        return @banner_token if defined?(@banner_token)

        @banner_token = resolve_banner_token
      end

      def resolve_banner_token
        raw = session[:smart_token].presence
        return nil if raw.blank?

        BannerToken.for_session(Doorkeeper::AccessToken.by_token(raw), session[:duz])
      rescue StandardError => e
        Rails.logger.warn("[patient-banner] session token unusable: #{e.class}")
        nil
      end

      # A page that already names a record in its route keeps that name.
      # The banner supplies Patient/<session dfn> only when the route has
      # no record segment. Query-string dfn/id must not: `params` merges
      # them in, and the inherited identifier would audit a patient the
      # page did not open.
      def fhir_resource_type
        return "Patient" if banner_supplies_entity?

        super
      end

      def direct_audit_identifier
        return @patient_banner_audit_dfn if banner_supplies_entity?

        super
      end

      def banner_supplies_entity?
        @patient_banner_audit_dfn.present? && !route_names_record?
      end

      def route_names_record?
        ROUTE_RECORD_KEYS.any? { |key| route_param(key).present? }
      end

      def route_patient_disagrees?(session_dfn)
        route_dfn = route_param(:dfn)
        route_dfn.present? && route_dfn.to_s != session_dfn.to_s
      end

      def route_param(key)
        path = request.path_parameters
        path[key].presence || path[key.to_s].presence
      end
    end
  end
end
