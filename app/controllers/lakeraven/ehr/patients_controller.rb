# frozen_string_literal: true

module Lakeraven
  module EHR
    class PatientsController < ApplicationController
      before_action :enforce_patient_context!, only: :show
      skip_before_action :authorize_fhir_scope!, only: :create
      before_action :authorize_fhir_write_scope!, only: :create
      before_action :require_registration_scope!, only: :create

      def index
        patients = resolve_patient_search
        # Org-bound backend credentials only see their own organization's
        # patients (SmartAuthentication — Vardana conformance item 2).
        patients = patients.select { |p| organization_permits_patient?(p) } if organization_bound?

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

      def create
        raw = request.body.read
        fhir = begin
          JSON.parse(raw)
        rescue JSON::ParserError
          return render_operation_outcome(status: :bad_request, severity: "error",
            code: "invalid", diagnostics: "Request body is not valid JSON")
        end
        unless fhir.is_a?(Hash) && fhir["resourceType"] == "Patient"
          return render_operation_outcome(status: :bad_request, severity: "error",
            code: "invalid", diagnostics: "Request body must be a FHIR Patient resource")
        end

        reg = registration_params_from_fhir(fhir)
        result = RegistrationGateway.register(reg)

        if result[:success] && result[:dfn].to_i.positive?
          response.headers["Location"] = "#{request.base_url}#{request.path}/#{result[:dfn]}"
          render_fhir(created_patient_fhir(result[:dfn], reg), status: :created)
        elsif result[:success]
          render_operation_outcome(status: :bad_gateway, severity: "error", code: "exception",
            diagnostics: "Registration reported success but returned no patient identifier")
        else
          render_operation_outcome(status: gateway_http_status(result[:status]),
            severity: "error", code: gateway_issue_code(result[:status]), diagnostics: result[:error])
        end
      end

      private

      def enforce_patient_context!
        authorize_patient_context!(params[:dfn])
      end

      def require_registration_scope!
        return if system_scope? || user_context_scope?
        render_forbidden("Patient registration requires a user- or system-level write scope")
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

      SSN_SYSTEMS = [
        "http://hl7.org/fhir/sid/us-ssn",
        "urn:oid:2.16.840.1.113883.4.1"
      ].freeze

      def registration_params_from_fhir(fhir)
        name = Array(fhir["name"]).first
        name = {} unless name.is_a?(Hash)
        family = name["family"].to_s
        given = Array(name["given"]).join(" ")
        {
          name: [ family, given ].reject(&:empty?).join(","),
          sex: { "male" => "M", "female" => "F" }[fhir["gender"]],
          date_of_birth: fhir["birthDate"],
          ssn: ssn_from_identifiers(fhir["identifier"])
        }
      end

      def ssn_from_identifiers(identifiers)
        Array(identifiers).each { |i| return i["value"] if i.is_a?(Hash) && SSN_SYSTEMS.include?(i["system"]) }
        nil
      end

      def created_patient_fhir(dfn, reg)
        {
          resourceType: "Patient",
          id: dfn.to_s,
          identifier: [ { system: "https://lakeraven.com/fhir/sid/dfn", value: dfn.to_s } ],
          name: patient_name_fhir(reg[:name]),
          gender: { "M" => "male", "F" => "female" }[reg[:sex]],
          birthDate: reg[:date_of_birth]
        }.compact
      end

      def patient_name_fhir(joined)
        return nil if joined.to_s.empty?
        family, given = joined.split(",", 2)
        [ { family: family, given: (given ? given.split(" ") : []) }.compact ]
      end

      def gateway_http_status(status)
        { 422 => :unprocessable_content, 409 => :conflict, 503 => :service_unavailable }
          .fetch(status, :internal_server_error)
      end

      def gateway_issue_code(status)
        { 422 => "invalid", 409 => "conflict", 503 => "transient" }.fetch(status, "exception")
      end
    end
  end
end
