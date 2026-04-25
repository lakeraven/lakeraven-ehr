# frozen_string_literal: true

require "csv"

module Lakeraven
  module EHR
    # EhiExportService - Single-Patient Electronic Health Information Export
    #
    # ONC 170.315(b)(10) - Electronic Health Information Export
    #
    # Generates a complete EHI export for a single patient, including:
    #   - FHIR clinical resources as NDJSON
    #   - Audit log entries related to the patient as CSV
    #   - System configuration summary
    #   - Manifest (CCG requirement)
    class EhiExportService
      FHIR_RESOURCE_TYPES = %w[
        Patient AllergyIntolerance Condition MedicationRequest Observation
      ].freeze

      AUDIT_CSV_HEADERS = [ "Timestamp", "Event Type", "Action", "Outcome", "Resource Type", "Resource ID", "Description" ].freeze

      def initialize(patient_dfn:, since: nil, before: nil)
        @patient_dfn = patient_dfn
        @since = since
        @before = before
      end

      def export
        patient = Patient.find_by_dfn(@patient_dfn)
        return failure("Patient not found: #{@patient_dfn}") unless patient

        files = []
        files.concat(export_fhir_resources(patient))
        files << export_audit_log
        files << export_configuration
        files << build_manifest(files)

        { success: true, files: files, patient_dfn: @patient_dfn, exported_at: Time.current.iso8601 }
      rescue => e
        failure("Export failed: #{e.message}")
      end

      private

      def failure(message)
        { success: false, errors: [ message ], files: [] }
      end

      def export_fhir_resources(patient)
        FHIR_RESOURCE_TYPES.map { |type| export_fhir_type(type, patient) }
      end

      def export_fhir_type(resource_type, patient)
        resources = fetch_resources(resource_type, patient)
        ndjson = resources.map { |r| fhir_to_json(r) }.join

        {
          name: "#{resource_type.underscore}.ndjson",
          type: "fhir_ndjson",
          resource_type: resource_type,
          count: resources.length,
          content: ndjson
        }
      end

      def fetch_resources(resource_type, patient)
        case resource_type
        when "Patient"
          [ patient ]
        when "AllergyIntolerance"
          AllergyIntolerance.for_patient(@patient_dfn)
        when "Condition"
          fetch_conditions
        when "MedicationRequest"
          MedicationRequest.for_patient(@patient_dfn)
        when "Observation"
          fetch_observations
        else
          []
        end
      rescue => e
        Rails.logger.warn("EHI export: failed to fetch #{resource_type}: #{e.message}")
        []
      end

      def fetch_conditions
        Condition.respond_to?(:for_patient) ? Condition.for_patient(@patient_dfn) : []
      rescue
        []
      end

      def fetch_observations
        Observation.respond_to?(:for_patient) ? Observation.for_patient(@patient_dfn) : []
      rescue
        []
      end

      def fhir_to_json(resource)
        fhir = resource.respond_to?(:to_fhir) ? resource.to_fhir : resource
        json = fhir.respond_to?(:as_json) ? fhir.as_json : fhir.to_h
        "#{json.to_json}\n"
      end

      # ---------------------------------------------------------------------------
      # Audit log CSV
      # ---------------------------------------------------------------------------

      def export_audit_log
        events = AuditEvent.where(entity_identifier: @patient_dfn)
        events = events.order(created_at: :desc).limit(10_000)

        csv_content = CSV.generate do |csv|
          csv << AUDIT_CSV_HEADERS
          events.each do |event|
            csv << [
              event.created_at&.iso8601,
              event.event_type,
              AuditEvent::ACTIONS[event.action] || event.action,
              AuditEvent::OUTCOMES[event.outcome] || event.outcome,
              event.entity_type,
              event.entity_identifier,
              sanitize_csv_value(event.outcome_desc)
            ]
          end
        end

        {
          name: "audit_log.csv",
          type: "audit_csv",
          count: events.count,
          content: csv_content
        }
      end

      # ---------------------------------------------------------------------------
      # Configuration summary
      # ---------------------------------------------------------------------------

      def export_configuration
        config = {
          data_sources: {
            clinical_data: "RPMS/VistA via RPC Broker",
            audit_data: "PostgreSQL (local)",
            fhir_version: "R4",
            us_core_version: "3.1.1"
          },
          export_formats: {
            fhir_resources: "NDJSON (application/fhir+ndjson)",
            audit_log: "CSV (text/csv)",
            configuration: "JSON (application/json)",
            manifest: "JSON (application/json)"
          },
          system_info: {
            application: "Lakeraven EHR",
            fhir_profiles: "US Core 3.1.1",
            certification_criterion: "ONC 170.315(b)(10)"
          }
        }

        {
          name: "configuration.json",
          type: "configuration",
          content: JSON.pretty_generate(config)
        }
      end

      # ---------------------------------------------------------------------------
      # Manifest (CCG requirement)
      # ---------------------------------------------------------------------------

      def build_manifest(files)
        manifest = {
          certification_criterion: "ONC 170.315(b)(10) - Electronic Health Information Export",
          format: "Single-patient EHI export containing FHIR R4 NDJSON, audit CSV, and configuration JSON",
          exported_at: Time.current.iso8601,
          patient_dfn: @patient_dfn,
          filters: build_filters,
          files: files.map { |f| { name: f[:name], type: f[:type], count: f[:count] }.compact }
        }

        {
          name: "manifest.json",
          type: "manifest",
          content: JSON.pretty_generate(manifest)
        }
      end

      def build_filters
        filters = {}
        filters[:since] = @since.iso8601 if @since
        filters[:before] = @before.iso8601 if @before
        filters.presence
      end

      def sanitize_csv_value(value)
        return value unless value.is_a?(String)
        value.start_with?("=", "+", "-", "@") ? "'#{value}" : value
      end
    end
  end
end
