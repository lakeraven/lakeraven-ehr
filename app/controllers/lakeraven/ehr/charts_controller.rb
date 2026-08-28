# frozen_string_literal: true

module Lakeraven
  module EHR
    # Read-only demo patient chart (issue #452), AUTHENTICATED with a
    # dev-only demo bypass.
    #
    # Inherits ActionController::Base (needed to render the HTML view) rather
    # than the engine's ActionController::API FHIR base, but reuses the SAME
    # protections the FHIR controllers apply, enforced for BOTH the HTML and
    # the FHIR-JSON paths and FAILING CLOSED:
    #   * SmartAuthentication — Doorkeeper bearer token required.
    #   * Per-resource read scope — the chart aggregates many resource types;
    #     it requires `Patient` read scope (else 403 for the whole request)
    #     and OMITS any individual section the token cannot read.
    #   * Patient-context binding — a patient-scoped token is bound to :dfn.
    #   * AuditableClinicalAccess — every authenticated access is audited.
    #
    # Unauthorized/forbidden responses are FORMAT-AWARE: FHIR requests get an
    # OperationOutcome (application/fhir+json); HTML requests get plain text.
    #
    # Demo bypass: authentication is skipped ONLY when
    #   Rails.env.development? && CHART_DEMO_OPEN=1 && SPIKE_MOCK_RPC=1
    # so the local synthetic demo opens with no token. The `development?` guard
    # makes the bypass impossible in test or production, and the mock-RPC guard
    # keeps it from ever fronting a real backend. Host browser-session
    # -> token SSO is a documented follow-up (ADR 0004), out of scope here.
    #
    # ONE endpoint, content-negotiated:
    #   GET /chart/:dfn            -> clinician-facing HTML chart
    #   GET /chart/:dfn.json       -> FHIR R4 Bundle (searchset)
    #   Accept: application/fhir+json / ?_format=json also yield the Bundle
    #
    # Data flows through the engine's real gateways/models + `.to_fhir`
    # serializers; only the RPMS data source is mocked (see
    # test/dummy/lib/lakeraven_demo_seeds.rb).
    class ChartsController < ActionController::Base
      include SmartAuthentication
      include AuditableClinicalAccess

      FHIR_CONTENT_TYPE = "application/fhir+json"

      before_action :authenticate_chart_request!
      before_action :require_patient_scope!
      before_action :enforce_patient_context!

      # RPMS problem-list status codes -> FHIR clinical-status
      PROBLEM_STATUS = { "A" => "active", "I" => "inactive" }.freeze
      # ORWPT APPTLST status text -> FHIR Encounter.status
      APPOINTMENT_STATUS = {
        "scheduled" => "planned", "checked in" => "arrived",
        "checked out" => "finished", "cancelled" => "cancelled",
        "no show" => "cancelled"
      }.freeze

      def show
        @patient = Patient.find_by_dfn(params[:dfn])
        return render_missing_patient unless @patient

        load_clinical_collections

        if fhir_requested?
          render json: fhir_bundle, content_type: FHIR_CONTENT_TYPE
        else
          render :show, layout: false
        end
      end

      private

      # -- Authentication / authorization (fail closed) -------------------------

      # Dev-only escape hatch so tomorrow's LOCAL demo opens with no token.
      # Guarded on development? so it can NEVER apply in test or production,
      # and on the mock-RPC flag so it can never expose a real backend.
      def demo_bypass?
        Rails.env.development? && ENV["CHART_DEMO_OPEN"] == "1" && ENV["SPIKE_MOCK_RPC"] == "1"
      end

      def authenticate_chart_request!
        return true if demo_bypass?

        authenticate_smart_token! # renders 401 (format-aware) + halts on failure
      end

      # The chart always includes Patient demographics; without Patient read
      # scope there is nothing safe to show -> deny the whole request.
      def require_patient_scope!
        return true if demo_bypass?
        return true if can_read?("Patient")

        render_forbidden("Insufficient scope to read Patient")
        false
      end

      def enforce_patient_context!
        return true if demo_bypass?

        authorize_patient_context!(params[:dfn]) # renders 403 (format-aware) on mismatch
      end

      # True when the caller is permitted to see a given resource type. The
      # dev bypass grants everything; otherwise it defers to the token scopes.
      def readable?(resource_type)
        demo_bypass? || can_read?(resource_type)
      end

      # AuditableClinicalAccess records entity_type from this; the chart is a
      # Patient-centric aggregate, so audit it against Patient + the dfn.
      def fhir_resource_type
        "Patient"
      end

      # AuditableClinicalAccess hook: demo-bypass requests carry no token but
      # must still leave an audit trail, under a dedicated fixed service actor
      # (independent security review finding). The entity identifier stays the
      # route dfn — no additional PHI enters the log.
      def unauthenticated_audit_actor
        "demo-bypass" if demo_bypass?
      end

      # -- Content negotiation --------------------------------------------------

      def fhir_requested?
        return true if params[:format].to_s == "json"
        return true if params[:_format].to_s == "json"

        request.headers["Accept"].to_s.include?("application/fhir+json")
      end

      # -- Data loading (per-type scope enforced; a mock miss yields []) --------

      def load_clinical_collections
        dfn = @patient.dfn.to_s
        @conditions    = readable?("Condition") ? build_conditions(dfn) : []
        @medications   = readable?("MedicationRequest") ? build_medications(dfn) : []
        @allergies     = readable?("AllergyIntolerance") ? build_allergies(dfn) : []
        @vitals        = readable?("Observation") ? safe { ObservationGateway.for_patient(dfn) } : []
        @observations  = Observation.from_vital_hashes(@vitals, patient_dfn: dfn)
        @immunizations = readable?("Immunization") ? safe { Immunization.for_patient(dfn) } : []
        @procedures    = readable?("Procedure") ? build_procedures(dfn) : []
        @encounters    = readable?("Encounter") ? safe { EncounterGateway.for_patient(dfn) } : []
        @encounter_resources = build_encounter_resources(dfn)
      end

      def build_conditions(dfn)
        safe { Condition.for_patient(dfn) }.map do |h|
          Condition.new(
            ien: problem_id(dfn, h), patient_dfn: dfn,
            code: h[:icd_code], code_system: "icd10", display: h[:description],
            clinical_status: PROBLEM_STATUS[h[:status]] || "active",
            category: "problem-list-item"
          )
        end
      end

      # Same deterministic-id policy as allergy_id: prefer a real IEN, else
      # derive a stable id (never random/urn:uuid) so the Bundle entry's
      # relative `subject` reference stays resolvable per Bundle rules.
      def problem_id(dfn, hash)
        hash[:ien].to_s.presence || "problem-#{dfn}-#{hash[:icd_code].to_s.parameterize}"
      end

      def build_medications(dfn)
        safe { MedicationRequest.for_patient(dfn) }.map do |h|
          MedicationRequest.new(
            ien: h[:ien]&.to_s, patient_dfn: dfn,
            medication_display: h[:drug_name], dosage_instruction: h[:sig],
            status: valid_status(h[:status], MedicationRequest::VALID_STATUSES, "active"),
            intent: "order"
          )
        end
      end

      # `status` has a REQUIRED binding in FHIR. RPMS status text like
      # "ACTIVE"/"DISCONTINUED" must never pass through raw: normalize to
      # lowercase, keep it only if it is a legal code, else fall back.
      def valid_status(raw, valid, fallback)
        normalized = raw.to_s.strip.downcase
        valid.include?(normalized) ? normalized : fallback
      end

      def build_allergies(dfn)
        safe { AllergyIntolerance.for_patient(dfn) }.map do |h|
          AllergyIntolerance.new(
            ien: allergy_id(dfn, h), patient_dfn: dfn,
            allergen: h[:allergen], reaction: h[:reaction],
            severity: h[:severity], clinical_status: "active",
            criticality: h[:severity].to_s.downcase == "severe" ? "high" : "low"
          )
        end
      end

      # ORQQAL LIST (the allergy RPC) returns ALLERGEN^REACTION^SEVERITY with no
      # IEN, so these records carry no natural identifier. Prefer a real IEN if
      # one ever appears; otherwise derive a DETERMINISTIC id from dfn + allergen
      # so AllergyIntolerance#to_fhir emits a stable, resolvable fullUrl (never
      # random/urn:uuid). AllergyIntolerance#to_fhir turns this into `id`.
      def allergy_id(dfn, hash)
        hash[:ien].to_s.presence || "allergy-#{dfn}-#{hash[:allergen].to_s.parameterize}"
      end

      def build_procedures(dfn)
        safe { Procedure.for_patient(dfn) }.map do |h|
          Procedure.new(
            ien: h[:ien]&.to_s, patient_dfn: dfn,
            display: h[:name],
            status: valid_status(h[:status], Procedure::VALID_STATUSES, "completed"),
            performed_datetime: h[:date]
          )
        end
      end

      def build_encounter_resources(dfn)
        @encounters.map do |h|
          Encounter.new(
            status: APPOINTMENT_STATUS[h[:status].to_s.downcase] || "planned",
            class_code: "AMB", period_start: h[:datetime],
            patient_identifier: dfn, location_ien: h[:location_ien]
          )
        end
      end

      def safe
        Array(yield)
      rescue => e
        Rails.logger.warn("[chart] clinical fetch failed: #{e.class}: #{e.message}")
        []
      end

      # -- FHIR Bundle ----------------------------------------------------------

      def fhir_bundle
        resources = [ @patient.to_fhir ]
        resources.concat(@conditions.map(&:to_fhir))
        resources.concat(@medications.map(&:to_fhir))
        resources.concat(@allergies.map(&:to_fhir))
        resources.concat(@observations.map(&:to_fhir))
        resources.concat(@immunizations.map(&:to_fhir))
        resources.concat(@procedures.map(&:to_fhir))
        resources.concat(@encounter_resources.map { |e| encounter_to_fhir(e) })

        {
          resourceType: "Bundle",
          id: SecureRandom.uuid,
          meta: { lastUpdated: Time.current.iso8601 },
          type: "searchset",
          total: resources.length,
          link: [ { relation: "self", url: request.original_url } ],
          entry: resources.map do |r|
            { fullUrl: entry_full_url(r), resource: r, search: { mode: "match" } }
          end
        }
      end

      # Chart appointments (ORWPT APPTLST) carry no visit IEN, so the derived
      # Encounter has no natural id. Derive a DETERMINISTIC, stable id from the
      # patient dfn + appointment start (not random/urn:uuid) so the same
      # appointment yields the same resolvable fullUrl on every request. If a
      # real visit IEN ever flows through, Encounter#to_fhir uses it and this
      # fallback is skipped.
      def encounter_to_fhir(encounter)
        fhir = encounter.to_fhir
        fhir[:id] ||= "appt-#{encounter.patient_identifier}-#{encounter.period_start&.strftime('%Y%m%d%H%M')}"
        fhir
      end

      # Absolute fullUrl for a resource. Resources whose serializer emits an id
      # get a REST URL under the engine's ACTUAL mount point (previously the
      # hardcoded `/fhir/` prefix pointed at a path that doesn't exist);
      # resources without an id get a valid urn:uuid so the Bundle stays
      # FHIR-conformant.
      def entry_full_url(resource)
        id = resource[:id]
        if id.present?
          "#{request.base_url}#{engine_mount_path}/#{resource[:resourceType]}/#{id}"
        else
          "urn:uuid:#{SecureRandom.uuid}"
        end
      end

      # Path where the host app mounted the engine (e.g. "/lakeraven-ehr" in
      # test/dummy). Falls back to "" (host root) if the host defined the
      # engine's routes without mounting it under a prefix.
      def engine_mount_path
        @engine_mount_path ||=
          main_app.respond_to?(:lakeraven_ehr_path) ? main_app.lakeraven_ehr_path : ""
      end

      # -- Format-aware auth failures (override SmartAuthentication) -------------
      #
      # SmartAuthentication#render_unauthorized/#render_forbidden emit FHIR JSON
      # unconditionally. A browser hitting the HTML chart should get plain text,
      # not a FHIR OperationOutcome — so branch on the requested representation.

      def render_unauthorized(message = "Unauthorized")
        render_auth_outcome(:unauthorized, "login", message)
      end

      def render_forbidden(message = "Forbidden")
        render_auth_outcome(:forbidden, "forbidden", message)
      end

      def render_auth_outcome(status, code, message)
        if fhir_requested?
          render json: {
            resourceType: "OperationOutcome",
            issue: [ { severity: "error", code: code, diagnostics: message } ]
          }, status: status, content_type: FHIR_CONTENT_TYPE
        else
          render plain: "#{status.to_s.titleize}: #{message}", status: status
        end
      end

      # -- 404 ------------------------------------------------------------------

      def render_missing_patient
        if fhir_requested?
          render json: {
            resourceType: "OperationOutcome",
            issue: [ { severity: "error", code: "not-found",
                       diagnostics: "Patient/#{params[:dfn]} not found" } ]
          }, status: :not_found, content_type: FHIR_CONTENT_TYPE
        else
          render plain: "Patient #{params[:dfn]} not found", status: :not_found
        end
      end
    end
  end
end
