# frozen_string_literal: true

module Lakeraven
  module EHR
    class PatientsController < ApplicationController
      before_action :enforce_patient_context!, only: :show

      def index
        patients = resolve_patient_search

        entries = patients.map { |p| build_patient_entry(p) }

        if params[:_revinclude] == "Provenance:target"
          patients.each do |p|
            ProvenanceStore.instance.for_target("Patient", "rpms-#{p.dfn}").each do |prov|
              entries << { resource: prov.to_fhir, search: { mode: "include" } }
            end
          end
        end

        render json: {
          resourceType: "Bundle", type: "searchset",
          total: entries.length, entry: entries
        }, status: :ok, content_type: FHIR_CONTENT_TYPE
      end

      def show
        patient = Patient.find_by_dfn(params[:dfn])

        if patient.nil?
          render_operation_outcome(
            status: :not_found,
            severity: "error",
            code: "not-found",
            diagnostics: "Patient not found"
          )
          return
        end

        render_fhir(patient.to_fhir)
      end

      private

      def enforce_patient_context!
        authorize_patient_context!(params[:dfn])
      end

      def resolve_patient_search
        if params[:_id].present?
          patient = Patient.find_by_dfn(params[:_id])
          patient ? [ patient ] : []
        elsif params[:identifier].present?
          ssn = extract_ssn_from_identifier(params[:identifier])
          ssn ? Patient.search_by_ssn(ssn) : []
        elsif params[:name].present?
          results = Patient.search(params[:name])
          results = filter_by_birthdate(results) if params[:birthdate].present?
          results = filter_by_gender(results) if params[:gender].present?
          results
        else
          Patient.search("")
        end
      end

      def extract_ssn_from_identifier(identifier)
        # Accept system|value format (e.g. http://hl7.org/fhir/sid/us-ssn|111-11-1111)
        parts = identifier.split("|")
        parts.length == 2 ? parts[1] : identifier
      end

      def filter_by_birthdate(patients)
        target = Date.parse(params[:birthdate]) rescue nil
        return patients unless target

        patients.select { |p| p.dob == target }
      end

      def filter_by_gender(patients)
        sex_code = case params[:gender]
                   when "male" then "M"
                   when "female" then "F"
                   else nil
        end
        return patients unless sex_code

        patients.select { |p| p.sex == sex_code }
      end

      def build_patient_entry(patient)
        { resource: patient.to_fhir, search: { mode: "match" } }
      end
    end
  end
end
