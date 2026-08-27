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
    #   Rails.env.development? && ENV["CHART_DEMO_OPEN"] == "1"
    # so the local synthetic demo opens with no token. The `development?` guard
    # makes the bypass impossible in test or production. Host browser-session
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
      # Guarded on development? so it can NEVER apply in test or production.
      def demo_bypass?
        Rails.env.development? && ENV["CHART_DEMO_OPEN"] == "1"
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
            ien: h[:ien]&.to_s, patient_dfn: dfn,
            code: h[:icd_code], code_system: "icd10", display: h[:description],
            clinical_status: PROBLEM_STATUS[h[:status]] || "active",
            category: "problem-list-item"
          )
        end
      end

      def build_medications(dfn)
        safe { MedicationRequest.for_patient(dfn) }.map do |h|
          MedicationRequest.new(
            ien: h[:ien]&.to_s, patient_dfn: dfn,
            medication_display: h[:drug_name], dosage_instruction: h[:sig],
            status: h[:status].presence || "active", intent: "order"
          )
        end
      end

      def build_allergies(dfn)
        safe { AllergyIntolerance.for_patient(dfn) }.map do |h|
          AllergyIntolerance.new(
            ien: h[:ien]&.to_s, patient_dfn: dfn,
            allergen: h[:allergen], reaction: h[:reaction],
            severity: h[:severity], clinical_status: "active",
            criticality: h[:severity].to_s.downcase == "severe" ? "high" : "low"
          )
        end
      end

      def build_procedures(dfn)
        safe { Procedure.for_patient(dfn) }.map do |h|
          Procedure.new(
            ien: h[:ien]&.to_s, patient_dfn: dfn,
            display: h[:name], status: h[:status].presence || "completed",
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
        resources.concat(@encounter_resources.map(&:to_fhir))

        {
          resourceType: "Bundle",
          id: SecureRandom.uuid,
          meta: { lastUpdated: Time.current.iso8601 },
          type: "searchset",
          total: resources.length,
          link: [ { relation: "self", url: request.original_url } ],
          entry: resources.map { |r| { fullUrl: entry_full_url(r), resource: r } }
        }
      end

      # Absolute fullUrl for a resource. Resources whose serializer emits an id
      # get a resolvable REST URL; those without (e.g. AllergyIntolerance) get
      # a valid urn:uuid so the Bundle stays FHIR-conformant.
      def entry_full_url(resource)
        id = resource[:id]
        if id.present?
          "#{request.base_url}/fhir/#{resource[:resourceType]}/#{id}"
        else
          "urn:uuid:#{SecureRandom.uuid}"
        end
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
