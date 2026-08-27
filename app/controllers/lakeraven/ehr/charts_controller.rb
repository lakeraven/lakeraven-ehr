# frozen_string_literal: true

module Lakeraven
  module EHR
    # Read-only, UNAUTHENTICATED demo patient chart (issue #452).
    #
    # Deliberately does NOT inherit from the engine's FHIR ApplicationController
    # (ActionController::API + SMART bearer auth + patient-context enforcement):
    # this is a public demo surface a clinician opens directly in a browser.
    # No before_action auth of any kind is applied here.
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
      FHIR_CONTENT_TYPE = "application/fhir+json"

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

      # -- Content negotiation --------------------------------------------------

      def fhir_requested?
        return true if params[:format].to_s == "json"
        return true if params[:_format].to_s == "json"

        request.headers["Accept"].to_s.include?("application/fhir+json")
      end

      # -- Data loading (each source guarded so a mock miss just yields []) ------

      def load_clinical_collections
        dfn = @patient.dfn.to_s
        @conditions    = build_conditions(dfn)
        @medications   = build_medications(dfn)
        @allergies     = build_allergies(dfn)
        @vitals        = safe { ObservationGateway.for_patient(dfn) }
        @observations  = Observation.from_vital_hashes(@vitals, patient_dfn: dfn)
        @immunizations = safe { Immunization.for_patient(dfn) }
        @procedures    = build_procedures(dfn)
        @encounters    = safe { EncounterGateway.for_patient(dfn) } # raw appt hashes for display
        @encounter_resources = build_encounter_resources(dfn)       # model instances for FHIR
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
          type: "searchset",
          total: resources.length,
          entry: resources.map { |r| { resource: r } }
        }
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
